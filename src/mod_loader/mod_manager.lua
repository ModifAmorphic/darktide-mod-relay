-- mod_manager.lua — Relay's private scan/load/lifecycle driver.
--
-- Owns mods.lst scanning, run-result validation, outer-object lifecycle
-- driving, generation-aware per-mod Crashify metadata, one-strike outer failure
-- containment, guarded engine alerts, and developer-mode hot reload. Loading
-- is staged (community parity): a load pass spans one manager update per
-- mods.lst entry — the anchor update opens the pass (bookkeeping only), entry
-- i loads on update i after it, and updates fan out every update to whatever
-- is already loaded.
-- Stock-DMF-specific field transitions + stale-global retirement stay in
-- dmf_adapter.lua; the manager-agnostic startup duties (adapter establish, io
-- observer, the process-lifetime Crashify version property) are chassis-owned
-- (lifecycle.lua Step 1c) and run under ANY manager.
--
-- Full load/failure/reload contracts: docs/architecture/MOD_LOADER-DMF.md.

local _pcall = pcall
local _xpcall = xpcall
local _tostring = tostring
local _type = type
local _rawget = rawget
local _ipairs = ipairs
local _select = select
local _unpack = unpack
local _string_find = string.find
local _string_gsub = string.gsub
local _string_sub = string.sub

-- Leveled diagnostics (init.lua publishes the helper on Mods._relay before this
-- module loads). Pcall-guarded so diagnostics never become a second failure path.
-- log_trace is source-gated (no-op unless --log-level trace / RELAY_LOG_LEVEL=trace).
local log_info  = Mods._relay.log_info
local log_debug = Mods._relay.log_debug
local log_warn  = Mods._relay.log_warn
local log_error = Mods._relay.log_error
local log_trace = Mods._relay.log_trace

local ModManager = class("ModManager")

local MOD_NAME_MAX_BYTES = 120
local DISPLAY_NAME_MAX_BYTES = 80
local ALERT_REMINDER_SECONDS = 15
local ALERT_STATE_ENTER_SECONDS = 2

local function pack(...)
    return { n = _select("#", ...), ... }
end

local function safe_text(value)
    local ok, text = _pcall(_tostring, value)
    if ok and _type(text) == "string" then
        return text
    end
    return "<unprintable error>"
end

local function display_name(name)
    if _type(name) ~= "string" then
        return "<invalid entry name>"
    end
    local rendered = _string_gsub(name, "%c", "?")
    if #rendered > DISPLAY_NAME_MAX_BYTES then
        rendered = _string_sub(rendered, 1, DISPLAY_NAME_MAX_BYTES - 3) .. "..."
    end
    if rendered == "" then
        return "<empty entry name>"
    end
    return rendered
end

local function failure_detail(err)
    local text = safe_text(err)
    local relay = (_type(Mods) == "table") and _rawget(Mods, "_relay") or nil
    local traceback_fn = (_type(relay) == "table") and _rawget(relay, "traceback") or nil
    if _type(traceback_fn) == "function" then
        local ok, traced = _pcall(traceback_fn, text, 2)
        if ok and _type(traced) == "string" then
            return traced
        end
    end
    return text .. "\n<traceback unavailable>"
end

local function protected_failure_detail(err)
    local ok, detail = _pcall(failure_detail, err)
    if ok and _type(detail) == "string" then
        return detail
    end
    return "<unprintable error>\n<traceback unavailable>"
end

function ModManager:init()
    -- The chassis (lifecycle.lua) loads dmf_adapter exactly once per process
    -- and publishes it on Mods._relay; read it here. A missing module means a
    -- corrupted install: fail creation with a clear error so the bootstrap
    -- wrapper logs + retries (same semantics as a failed module load).
    local relay = (_type(Mods) == "table") and _rawget(Mods, "_relay") or nil
    local dmf_adapter = (_type(relay) == "table") and _rawget(relay, "dmf_adapter") or nil
    if _type(dmf_adapter) ~= "table" or _type(dmf_adapter.new) ~= "function" then
        error("dmf_adapter module unavailable on Mods._relay (corrupted install?)")
    end
    self._adapter = dmf_adapter.new(self)

    self._mods = {}
    self._mods_loaded = false
    self._load_cursor = nil
    self._pass_kind = nil
    self._pass_had_errors = false
    self._generation = 0
    self._load_target_generation = nil
    self._stop_load_pass = false
    self._generation_failed = false
    self._generation_globals_retired = false

    self._reload_requested = false
    self._reload_in_progress = false
    self._reload_degraded = false
    self._reload_data = nil

    self._cleanup_queue = {}
    self._cleanup_draining = false
    self._failure_records = {}
    self._alert_clock = 0
    self._alert_last_attempt = nil
    self._alert_unavailable_logged = false

    self._crashify_keys = {}
    self._crashify_key_set = {}
    self._crashify_disabled = false
    self._crashify_unavailable_logged = false

    self._kb_resolved = false
    self._kb_r = nil
    self._kb_lshift = nil
    self._kb_lctrl = nil
    self._kb_unavailable_logged = false
    self._gsc_ignored_logged = false

    self:_scan_mods()
end

function ModManager:_scan_mods()
    self._mods = {}
    local order = Mods.file.read_content_to_table("mods.lst")
    if _type(order) == "table" then
        for idx, name in _ipairs(order) do
            self._mods[idx] = {
                id = idx,
                name = name,
                handle = name,
                state = "not_loaded",
                object = nil,
            }
        end
        log_debug("scan: " .. #order .. " entries from mods.lst")
        return true
    end
    log_warn("mods.lst missing or unreadable; no mods will load")
    return false
end

function ModManager:_active_generation()
    if _type(self._load_target_generation) == "number" then
        return self._load_target_generation
    end
    if self._generation > 0 then
        return self._generation
    end
    return 1
end

-- ---------------------------------------------------------------------------
-- Optional Crashify integration.
-- ---------------------------------------------------------------------------

function ModManager:_disable_crashify(message)
    self._crashify_disabled = true
    log_warn(message)
end

function ModManager:_crashify_call(method_name, context, ...)
    if self._crashify_disabled then
        return false
    end
    local args = pack(...)
    local ok, available = _pcall(function()
        local crashify = _rawget(_G, "Crashify")
        if _type(crashify) ~= "table" then
            return false
        end
        local method = crashify[method_name]
        if _type(method) ~= "function" then
            return false
        end
        method(_unpack(args, 1, args.n))
        return true
    end)
    if not ok then
        self:_disable_crashify("Crashify " .. context
            .. " failed; crash metadata disabled for this generation")
        return false
    end
    if not available then
        self._crashify_disabled = true
        if not self._crashify_unavailable_logged then
            log_debug("Crashify unavailable; optional crash metadata will retry next generation")
            self._crashify_unavailable_logged = true
        end
        return false
    end
    return true
end

function ModManager:_prepare_crashify_generation(remove_old)
    self._crashify_disabled = false
    if remove_old then
        for _, key in _ipairs(self._crashify_keys) do
            if not self:_crashify_call("remove_print_property", "stale-key removal", key) then
                break
            end
        end
        -- Tracking reflects the new generation even when optional removal is
        -- unavailable. Never carry old keys into the replacement set.
        self._crashify_keys = {}
        self._crashify_key_set = {}
    end
end

function ModManager:_publish_mod_property(entry)
    if self._crashify_disabled then
        return
    end
    local name = entry and entry.name
    if _type(name) ~= "string" or name == "" or #name > MOD_NAME_MAX_BYTES
       or _string_find(name, "%c") then
        log_debug("Crashify mod metadata skipped for entry id " .. safe_text(entry and entry.id)
            .. " (name is empty, unsafe, or over 120 bytes)")
        return
    end
    local key = "Mod:" .. name
    if self._crashify_key_set[key] then
        return
    end
    if self:_crashify_call("print_property", "mod publication", key, true) then
        self._crashify_key_set[key] = true
        self._crashify_keys[#self._crashify_keys + 1] = key
    end
end

-- ---------------------------------------------------------------------------
-- Failure records, independent engine alerts, and exactly-once cleanup.
-- ---------------------------------------------------------------------------

function ModManager:_developer_mode_for_alert()
    local ok, enabled = _pcall(function()
        return self._adapter:developer_mode_enabled()
    end)
    return ok and enabled == true
end

function ModManager:_alert_suffix()
    if self:_developer_mode_for_alert() then
        return "Restart the game or hot reload in developer mode. See the Darktide console log for details."
    end
    return "Restart the game. See the Darktide console log for details."
end

function ModManager:_attempt_alert(message)
    self._alert_last_attempt = self._alert_clock
    local ok, available = _pcall(function()
        local managers = _rawget(_G, "Managers")
        if _type(managers) ~= "table" then
            return false
        end
        local event = managers.event
        if _type(event) ~= "table" then
            return false
        end
        local trigger = event.trigger
        if _type(trigger) ~= "function" then
            return false
        end
        trigger(event, "event_add_notification_message", "alert", { text = message })
        return true
    end)
    if ok and available then
        self._alert_unavailable_logged = false
        return true
    end
    if not self._alert_unavailable_logged then
        log_warn("engine alert transport unavailable; failure notice will retry")
        self._alert_unavailable_logged = true
    end
    return false
end

function ModManager:_has_latched_failures()
    return #self._failure_records > 0
end

function ModManager:_framework_failure_latched()
    for _, record in _ipairs(self._failure_records) do
        if record.framework then
            return true
        end
    end
    return false
end

function ModManager:_reminder_message()
    if self:_framework_failure_latched() then
        return "Mod Relay stopped the current mod generation after a framework-boundary error. "
            .. self:_alert_suffix()
    end
    return "Mod Relay disabled one or more mods after lifecycle errors. "
        .. self:_alert_suffix()
end

function ModManager:_attempt_reminder_if_due(minimum_seconds)
    if not self:_has_latched_failures() then
        return
    end
    if self._alert_last_attempt ~= nil
       and self._alert_clock - self._alert_last_attempt < minimum_seconds then
        return
    end
    self:_attempt_alert(self:_reminder_message())
end

function ModManager:_prune_old_failure_records(generation)
    local retained = {}
    for _, record in _ipairs(self._failure_records) do
        if record.generation >= generation then
            retained[#retained + 1] = record
        end
    end
    self._failure_records = retained
    if #retained == 0 then
        self._alert_last_attempt = nil
        self._alert_unavailable_logged = false
    end
end

function ModManager:_queue_cleanup(entry, object)
    if entry == nil or object == nil or entry._cleanup_claimed then
        return
    end
    entry._cleanup_claimed = true
    entry._cleanup_object = object
    self._cleanup_queue[#self._cleanup_queue + 1] = { entry = entry, object = object }
end

function ModManager:_call_teardown(entry, object, callback, ...)
    local args = pack(...)
    local ok, implemented, result = _xpcall(function()
        local fn = object[callback]
        if _type(fn) ~= "function" then
            return false, nil
        end
        return true, fn(object, _unpack(args, 1, args.n))
    end, protected_failure_detail)
    if not ok then
        log_warn("mod '" .. display_name(entry and entry.name) .. "' " .. callback
            .. " failed during best-effort teardown: " .. safe_text(implemented))
        return false, nil, true
    end
    return true, result, implemented
end

function ModManager:_drain_cleanup(mark_reload_degraded)
    if self._cleanup_draining then
        return
    end
    self._cleanup_draining = true
    local queue = self._cleanup_queue
    self._cleanup_queue = {}
    for _, item in _ipairs(queue) do
        local entry = item.entry
        if not entry._cleanup_done then
            entry._cleanup_done = true
            local ok = self:_call_teardown(entry, item.object, "on_unload")
            if not ok and mark_reload_degraded then
                self._reload_degraded = true
            end
        end
        entry._cleanup_object = nil
    end
    self._cleanup_draining = false
end

function ModManager:_retire_generation_globals(mark_reload_degraded)
    if self._generation_globals_retired then
        return
    end
    self._generation_globals_retired = true
    local ok = _pcall(function()
        self._adapter:retire_stale_generation_globals()
    end)
    if not ok then
        log_warn("stale generation global retirement failed; cleanup remains best effort")
        if mark_reload_degraded then
            self._reload_degraded = true
        end
    end
end

function ModManager:_rebuild_framework_cleanup_queue(failed_entry, failed_object)
    -- A framework stop requires reverse load order even if a standalone entry
    -- already queued cleanup earlier in the same fan-out.
    self._cleanup_queue = {}
    for i = #self._mods, 1, -1 do
        local entry = self._mods[i]
        local object = entry.object
        if entry == failed_entry then
            object = failed_object
            entry.object = nil
            entry.state = "disabled"
        elseif object ~= nil then
            entry.object = nil
            if entry.state ~= "disabled" then
                entry.state = "stopped"
            end
        elseif entry.state == "not_loaded" then
            entry.state = "skipped"
        end

        if object ~= nil then
            if not entry._cleanup_claimed then
                entry._cleanup_claimed = true
                entry._cleanup_object = object
            end
            if not entry._cleanup_done then
                self._cleanup_queue[#self._cleanup_queue + 1] = {
                    entry = entry,
                    object = entry._cleanup_object or object,
                }
            end
        elseif entry._cleanup_claimed and not entry._cleanup_done
               and entry._cleanup_object ~= nil then
            self._cleanup_queue[#self._cleanup_queue + 1] = {
                entry = entry,
                object = entry._cleanup_object,
            }
        end
    end
end

function ModManager:_handle_lifecycle_failure(entry, object, callback, detail)
    if entry._failure_claimed then
        return
    end
    entry._failure_claimed = true
    local generation = self:_active_generation()
    local framework = entry.name == "dmf"
    entry.object = nil
    entry.state = "disabled"

    self._failure_records[#self._failure_records + 1] = {
        name = entry.name,
        generation = generation,
        callback = callback,
        detail = detail,
        framework = framework,
    }

    if framework then
        self._generation_failed = true
        self._stop_load_pass = true
        self:_rebuild_framework_cleanup_queue(entry, object)
        log_error("framework-boundary lifecycle failure at entry '" .. display_name(entry.name)
            .. "' in generation " .. generation .. " during " .. callback
            .. "; Relay stopped the current generation:\n" .. detail)
        self:_attempt_alert("Mod Relay stopped the current mod generation after a framework-boundary error. "
            .. self:_alert_suffix())
    else
        self:_queue_cleanup(entry, object)
        log_error("mod '" .. display_name(entry.name) .. "' " .. callback
            .. " failed in generation " .. generation
            .. "; Relay disabled this entry:\n" .. detail)
        self:_attempt_alert("Mod Relay disabled mod '" .. display_name(entry.name)
            .. "' after a lifecycle error. " .. self:_alert_suffix())
    end
end

function ModManager:_call_outer(entry, object, callback, ...)
    local args = pack(...)
    local ok, implemented, result = _xpcall(function()
        local fn = object[callback]
        if _type(fn) ~= "function" then
            return false, nil
        end
        return true, fn(object, _unpack(args, 1, args.n))
    end, protected_failure_detail)
    if not ok then
        self:_handle_lifecycle_failure(entry, object, callback, safe_text(implemented))
        return false, false, nil
    end
    return true, implemented, result
end

-- ---------------------------------------------------------------------------
-- Update, load, and hot reload.
-- ---------------------------------------------------------------------------

function ModManager:update(dt)
    if _type(dt) == "number" and dt > 0 then
        self._alert_clock = self._alert_clock + dt
    end

    self:_poll_reload_shortcut()

    if self._reload_requested then
        self._reload_requested = false
        -- Teardown supersedes any pass still in flight. Only the legacy
        -- direct-_reload_requested path can reach here mid-pass (the
        -- request_reload seam is refused while a pass runs); _begin_reload
        -- tears down whatever the aborted pass had loaded, so dropping the
        -- pass bookkeeping keeps the replacement pass from interleaving
        -- with it.
        self._load_cursor = nil
        self._pass_kind = nil
        self._pass_had_errors = false
        self._load_target_generation = nil
        self:_close_load_stage()
        self._adapter:end_load_pass()
        self:_begin_reload()
        self:_attempt_reminder_if_due(ALERT_REMINDER_SECONDS)
        return
    end

    if self._reload_in_progress and self._load_cursor == nil then
        -- First manager update after teardown: the replacement pass's anchor
        -- (no loads; the first entry loads on the next update).
        self:_begin_load_pass("reload", self._generation + 1)
    elseif not self._mods_loaded then
        self._mods_loaded = true
        self:_begin_load_pass("initial", 1)
    end

    if self._load_cursor ~= nil then
        self:_advance_load_pass()
    end

    self:_drive_update(dt)
    self:_attempt_reminder_if_due(ALERT_REMINDER_SECONDS)
end

function ModManager:request_reload(source)
    if not self._adapter:developer_mode_enabled() then
        return false, "developer_mode disabled"
    end
    if not self._adapter:is_load_done() then
        return false, "manager not done"
    end
    if self._reload_requested or self._reload_in_progress then
        return false, "reload already active"
    end
    self._reload_requested = true
    log_info("hot reload requested (source: " .. safe_text(source) .. ")")
    return true
end

function ModManager:_check_reload()
    if not self._kb_resolved then
        local ok = _pcall(function()
            local kb = Keyboard
            if _type(kb) ~= "table" then error("Keyboard unavailable") end
            local r = kb.button_index("r")
            local ls = kb.button_index("left shift")
            local lc = kb.button_index("left ctrl")
            if _type(r) ~= "number" or _type(ls) ~= "number" or _type(lc) ~= "number" then
                error("button_index returned non-number")
            end
            self._kb_r, self._kb_lshift, self._kb_lctrl = r, ls, lc
        end)
        if not ok then
            if not self._kb_unavailable_logged then
                log_debug("reload shortcut unavailable (keyboard not ready); will retry")
                self._kb_unavailable_logged = true
            end
            return false
        end
        self._kb_resolved = true
    end

    local pressed, mod_sum
    local ok = _pcall(function()
        pressed = Keyboard.pressed(self._kb_r)
        mod_sum = Keyboard.button(self._kb_lshift) + Keyboard.button(self._kb_lctrl)
    end)
    if not ok then
        self._kb_resolved = false
        if not self._kb_unavailable_logged then
            log_debug("reload shortcut unavailable (keyboard query failed); will retry")
            self._kb_unavailable_logged = true
        end
        return false
    end
    self._kb_unavailable_logged = false
    return pressed and mod_sum == 2
end

function ModManager:_poll_reload_shortcut()
    local ok, active = _pcall(function() return self:_check_reload() end)
    if ok and active then
        self:request_reload("keyboard")
    end
end

function ModManager:_begin_reload()
    self._adapter:mark_load_pending()
    self._reload_degraded = false

    -- Disabled entries may still have deferred cleanup. Drain it before any
    -- normal reload callbacks so no object can be claimed twice.
    self:_drain_cleanup(false)
    local old_mods = self._mods
    local reload_data = {}

    for i = 1, #old_mods do
        local entry = old_mods[i]
        local object = entry.object
        if object ~= nil then
            local ok, result, implemented = self:_call_teardown(entry, object, "on_reload")
            if ok and implemented then
                reload_data[entry.name] = result
            elseif not ok then
                self._reload_degraded = true
            end
        end
    end

    for i = #old_mods, 1, -1 do
        local entry = old_mods[i]
        local object = entry.object
        if object ~= nil then
            entry.object = nil
            self:_queue_cleanup(entry, object)
        end
    end
    self:_drain_cleanup(true)
    self:_retire_generation_globals(true)

    -- Old properties remain until teardown is complete. Clear only the tracked
    -- per-mod keys; the process-lifetime version property is never removed.
    self:_prepare_crashify_generation(true)

    local scan_ok, scan_had_order = _pcall(function()
        return self:_scan_mods()
    end)
    if not scan_ok then
        self._mods = {}
        log_error("mods.lst rescan error; loading empty mod set")
        self._reload_degraded = true
    elseif scan_had_order == false then
        self._reload_degraded = true
    end

    self._reload_data = reload_data
    self._reload_in_progress = true
end

-- One low-volume DEBUG summary line after the INITIAL load pass finalizes,
-- computed from the entry states ("failed" and "disabled" both count as
-- failed; a missing/empty mods.lst yields a sensible "0 entries" line here).
function ModManager:_log_load_pass_summary()
    local total = #self._mods
    local failed = 0
    for _, entry in _ipairs(self._mods) do
        local state = entry.state
        if state == "failed" or state == "disabled" then
            failed = failed + 1
        end
    end
    log_debug("initial load pass complete: " .. total .. " entries, " .. failed .. " failed")
end

-- Begin a load pass anchored on THIS manager update. The anchor update is
-- bookkeeping only: no entry loads until the next update. kind is "initial"
-- (first boot pass) or "reload" (post-teardown replacement); target_generation
-- is the generation the pass finalizes into.
function ModManager:_begin_load_pass(kind, target_generation)
    self._load_cursor = 0
    self._pass_kind = kind
    self._pass_had_errors = false
    self._load_target_generation = target_generation
    self._generation_failed = false
    self._stop_load_pass = false
    self._generation_globals_retired = false
    -- Every pass-ending path clears the stage epoch, but a pass that never
    -- began loading (or an aborted one) leaves nothing to inherit: a new pass
    -- always starts unstaged.
    self:_close_load_stage()
    if kind == "initial" then
        self:_prepare_crashify_generation(false)
        log_trace("load pass begin (initial)")
    else
        log_trace("load pass begin (reload, generation " .. target_generation .. ")")
    end
end

-- One manager update of an active load pass: advance at most one cursor step
-- (load at most the single entry it points at), then finalize when the pass
-- is complete, stopped, or escaped. The cursor field doubles as the active
-- flag (_load_cursor nil == no pass).
function ModManager:_advance_load_pass()
    local escape = nil

    -- A framework failure during a previous update's _drive_update can set
    -- the stop flag after that update's load: skip loading and finalize now.
    if not self._stop_load_pass then
        local cursor = self._load_cursor
        if cursor >= 1 then
            local entry = self._mods[cursor]
            if entry ~= nil then
                local ok, detail = _pcall(function()
                    return self:_load_pass_entry(cursor, entry)
                end)
                if not ok then
                    -- error(nil) escapes as a nil detail; a bare true keeps
                    -- the escape force-finalizing (safe_text renders it).
                    escape = detail or true
                end
            end
        end
    end

    self._load_cursor = self._load_cursor + 1

    if escape ~= nil or self._stop_load_pass or self._load_cursor > #self._mods then
        self:_finalize_load_pass(escape)
    end
end

-- The per-entry load step for one cursor position (the loop body of the
-- former single-update pass, sequence unchanged). Contained in a pcall by
-- _advance_load_pass; an escape force-finalizes with remaining entries left
-- not_loaded.
function ModManager:_load_pass_entry(cursor, entry)
    -- Stage epoch opens at the pass's FIRST load attempt (attempt-based: a
    -- failed first entry still opens it); the stamp helper derives stage=
    -- as current update - epoch while it is set.
    self:_open_load_stage()
    self._adapter:begin_load_entry(cursor)
    log_trace("load entry #" .. safe_text(entry.id) .. " '"
        .. display_name(entry.name) .. "'")
    if not self:_load_one(entry, self._reload_data) then
        self._pass_had_errors = true
    end
    log_trace("entry '" .. display_name(entry.name)
        .. "' result=" .. safe_text(entry.state))
    self:_drain_cleanup(false)
    if self._generation_failed then
        self:_drain_cleanup(false)
        self:_retire_generation_globals(false)
    end
end

-- Settle a finished load pass: collateral skip-marking, the DMF-visible field
-- transitions, the generation advance, and the kind-specific summary.
-- escape is non-nil when the per-entry step threw through its containment.
function ModManager:_finalize_load_pass(escape)
    local kind = self._pass_kind
    local target = self._load_target_generation

    if self._stop_load_pass then
        for _, entry in _ipairs(self._mods) do
            if entry.state == "not_loaded" then
                entry.state = "skipped"
            end
            -- The framework-failure rebuild may have pre-marked later entries
            -- skipped; either way, each non-loaded entry reports once, here.
            if entry.state == "skipped" then
                log_trace("entry '" .. display_name(entry.name) .. "' result=skipped")
            end
        end
    end

    self._adapter:end_load_pass()
    if kind == "reload" then
        self._reload_data = nil
        self._reload_in_progress = false
    end
    self._load_target_generation = nil
    self._generation = target
    self._adapter:mark_load_done()
    self._load_cursor = nil

    if kind == "initial" then
        self:_log_load_pass_summary()
        if escape ~= nil then
            log_error("initial mod load pass error: " .. safe_text(escape)
                .. "; initial generation finalized with errors")
        end
    else
        if escape ~= nil then
            log_error("hot reload load pass error: " .. safe_text(escape))
        end
        -- A framework stop mid-replay (drive-time fan-out failure) leaves
        -- _generation_failed set at finalize; a stopped generation is never
        -- a clean completion. Load-time failures already set _pass_had_errors.
        local degraded = self._reload_degraded or self._pass_had_errors
            or escape ~= nil or self._generation_failed
        self:_prune_old_failure_records(target)
        if degraded then
            log_warn("hot reload generation " .. self._generation
                .. " completed with errors; game restart recommended")
        else
            log_info("hot reload generation " .. self._generation .. " completed cleanly")
        end
        self._reload_degraded = false
    end

    -- The pass-end marker lands on the finalize update, after the
    -- kind-specific summary/completion lines (docs/reference/relay/logging.md).
    -- Emitted BEFORE the stage close so it carries the pass's final stage.
    log_trace("load pass end (" .. kind .. ", generation " .. target .. ")")
    self:_close_load_stage()

    self._pass_kind = nil
    self._pass_had_errors = false
end

-- Stage epoch (Mods._relay._stage_epoch): the update index of the current
-- pass's FIRST load attempt. The stamp helper (init.lua) derives the stamp's
-- `stage=` field as current update - epoch while the epoch is set, so stage is
-- 0 on the first loading update and +1 per update after. Set here (manager-
-- owned: the manager owns the pass lifecycle), cleared on every pass-ending
-- path — finalize, the teardown branch, destroy — plus defensively at pass
-- begin. Empty/missing mods.lst never loads an entry, so the epoch never
-- opens and no line is ever staged. Total over corrupted state (type checks;
-- never throws into engine code).
function ModManager:_open_load_stage()
    local relay = (_type(Mods) == "table") and _rawget(Mods, "_relay") or nil
    if _type(relay) ~= "table" or _type(relay._stage_epoch) == "number" then
        return
    end
    local now = relay._update
    if _type(now) ~= "number" or now < 0 then
        now = 0
    end
    relay._stage_epoch = now
end

function ModManager:_close_load_stage()
    local relay = (_type(Mods) == "table") and _rawget(Mods, "_relay") or nil
    if _type(relay) == "table" then
        relay._stage_epoch = nil
    end
end

function ModManager:_fail_load_entry(entry, reason)
    if entry then
        entry.object = nil
        entry.state = "failed"
    end
    self:_log_dmf_framework_failure(entry, reason)
    return false
end

function ModManager:_load_one(entry, reload_data)
    local valid, reason = self._adapter:validate_entry(entry)
    if not valid then
        log_warn("mod entry invalid (" .. safe_text(reason) .. "); skipped")
        return self:_fail_load_entry(entry, "entry invalid")
    end

    local name = entry.name
    local shown = display_name(name)
    local mod_data = Mods.file.exec_with_return(name .. "/" .. name .. ".mod")
    if mod_data == false then
        -- Safe exec already logged the accurate cause for an existing chunk
        -- that failed to compile/raise; this line covers the rest.
        log_error("mod '" .. shown .. "' .mod missing, unreadable, or failed to execute")
        return self:_fail_load_entry(entry, ".mod missing/unreadable")
    end
    local descriptor_ok, run_function = _pcall(function()
        if _type(mod_data) ~= "table" then
            return nil
        end
        local candidate = mod_data.run
        if _type(candidate) == "function" then
            return candidate
        end
        return nil
    end)
    if not descriptor_ok or run_function == nil then
        log_warn("mod '" .. shown .. "' .mod invalid (no run function)")
        return self:_fail_load_entry(entry, ".mod invalid")
    end

    -- DMF's DMFMod:init reads _mods[_mod_load_index].data (then .packages) during
    -- construction — inside run() for user mods, during init for DMF itself — so
    -- publish BEFORE run(); verbatim table, .packages validation is DMF-owned.
    entry.data = mod_data

    self:_publish_mod_property(entry)
    local ok_run, object = _pcall(run_function)
    if not ok_run then
        log_error("mod '" .. shown .. "' run failed: " .. safe_text(object))
        return self:_fail_load_entry(entry, "run failed")
    end

    local result_type = _type(object)
    if object == nil then
        entry.state = "dmf_driven"
        log_debug("mod '" .. shown .. "' DMF-driven (run returned no object)")
        return true
    end
    if result_type ~= "table" then
        -- Validate before assignment, member lookup, or value formatting.
        log_warn("mod '" .. shown .. "' run returned invalid type " .. result_type)
        return self:_fail_load_entry(entry, "run returned invalid type")
    end

    entry.object = object
    entry.state = "running"
    local data = reload_data and reload_data[name]
    local ok = self:_call_outer(entry, object, "init", data)
    if not ok then
        return false
    end
    return true
end

function ModManager:_log_dmf_framework_failure(entry, reason)
    if entry and entry.name == "dmf" then
        log_error("DMF FRAMEWORK LOAD FAILURE ('dmf' " .. reason
            .. "); load degraded — mods depending on DMF may not work")
    end
end

function ModManager:_drive_update(dt)
    if self._generation_failed then
        self:_drain_cleanup(false)
        return
    end
    for _, entry in _ipairs(self._mods) do
        local object = entry.object
        if object ~= nil then
            self:_call_outer(entry, object, "update", dt)
            if self._generation_failed then
                break
            end
        end
    end
    self:_drain_cleanup(false)
    if self._generation_failed then
        self:_retire_generation_globals(false)
    end
end

function ModManager:on_game_state_changed(status, state_name, state_object)
    -- Community parity: the initial pass spans multiple updates now, and boot
    -- state transitions can land inside it (e.g. StateTitle enter ~1 update
    -- after the anchor), so dispatch to already-loaded entries while the
    -- initial pass is actively loading — updates already flow to those same
    -- entries on those same updates, and the dispatch loop's nil-object skip
    -- limits delivery to loaded entries. Suppression stays load-bearing for
    -- the reload window (never dispatch into half-torn-down objects) and
    -- after destroy: a never-finalized pass is suppressed through the gate
    -- (settled fields -> not done), while after a done destroy the gate is
    -- open and the emptied entry table delivers nothing.
    local initial_pass_open = self._load_cursor ~= nil and self._pass_kind == "initial"
    if not self._adapter:is_load_done() and not initial_pass_open then
        if not self._gsc_ignored_logged then
            log_debug("on_game_state_changed ignored (reload/load in progress)")
            self._gsc_ignored_logged = true
        end
        return
    end
    self._gsc_ignored_logged = false

    if status == "enter" then
        self:_attempt_reminder_if_due(ALERT_STATE_ENTER_SECONDS)
    end
    if self._generation_failed then
        self:_drain_cleanup(false)
        return
    end

    for _, entry in _ipairs(self._mods) do
        local object = entry.object
        if object ~= nil then
            self:_call_outer(entry, object, "on_game_state_changed",
                             status, state_name, state_object)
            if self._generation_failed then
                break
            end
        end
    end
    self:_drain_cleanup(false)
    if self._generation_failed then
        self:_retire_generation_globals(false)
    end
end

function ModManager:destroy()
    -- A mid-pass destroy is terminal, not a completion: settle the pass
    -- fields defensively (no mark_load_done) so a later update() cannot
    -- resume loading entries after teardown, and clear the load index.
    -- A mid-REPLAY destroy settles the reload machinery too: without this,
    -- a later update() would begin a fresh replacement pass over the stale
    -- reload data. (_reload_requested/_reload_degraded stay with the normal
    -- machinery — both are harmless without _reload_in_progress.)
    self._load_cursor = nil
    self._pass_kind = nil
    self._pass_had_errors = false
    self._load_target_generation = nil
    self._reload_in_progress = false
    self._reload_data = nil
    self:_close_load_stage()
    self._adapter:end_load_pass()
    self:_drain_cleanup(false)
    for i = #self._mods, 1, -1 do
        local entry = self._mods[i]
        local object = entry.object
        if object ~= nil then
            entry.object = nil
            self:_queue_cleanup(entry, object)
        end
    end
    self:_drain_cleanup(false)
    -- Current-generation Crashify properties intentionally survive shutdown.
end

return ModManager
