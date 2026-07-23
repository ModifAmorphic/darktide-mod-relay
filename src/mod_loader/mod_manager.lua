-- mod_manager.lua — Relay's private scan/load/lifecycle driver.
--
-- The manager owns authoritative mods.lst scanning, nil/table run-result
-- validation, outer-object lifecycle driving, generation-aware Crashify
-- metadata, one-strike outer failure containment, guarded engine alerts, and
-- the existing two-frame developer-mode hot reload. Stock-DMF-specific field
-- transitions and stale-global retirement remain in dmf_adapter.lua.

local _pcall = pcall
local _xpcall = xpcall
local _tostring = tostring
local _type = type
local _rawget = rawget
local _ipairs = ipairs
local _select = select
local _unpack = unpack
local _print = __print or print
local _string_find = string.find
local _string_gsub = string.gsub
local _string_sub = string.sub

local dmf_adapter = Mods.load_module("dmf_adapter")
local ModManager = class("ModManager")

local VERSION_MAX_BYTES = 128
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

local function log(message)
    -- Diagnostics must never become a second failure path.
    _pcall(_print, "[mod_loader] " .. safe_text(message))
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
    self._adapter = dmf_adapter.new(self)
    self._adapter:establish()
    self._adapter:register_io_observer()

    self._mods = {}
    self._mods_loaded = false
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
    self._version_invalid_logged = false

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
        return true
    end
    log("mods.lst missing or unreadable; no mods will load")
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
    log(message)
end

function ModManager:_crashify_call(method_name, phase, ...)
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
        self:_disable_crashify("Crashify " .. phase
            .. " failed; crash metadata disabled for this generation")
        return false
    end
    if not available then
        self._crashify_disabled = true
        if not self._crashify_unavailable_logged then
            log("Crashify unavailable; optional crash metadata will retry next generation")
            self._crashify_unavailable_logged = true
        end
        return false
    end
    return true
end

function ModManager:_publish_version_property()
    local relay = (_type(Mods) == "table") and _rawget(Mods, "_relay") or nil
    if _type(relay) == "table" and relay.crashify_version_published == true then
        return
    end
    local version = (_type(relay) == "table") and _rawget(relay, "version") or nil
    if _type(version) ~= "string" or version == "" or #version > VERSION_MAX_BYTES
       or _string_find(version, "%c") then
        if not self._version_invalid_logged then
            log("Relay version crash metadata unavailable (missing or invalid private build value)")
            self._version_invalid_logged = true
        end
        return
    end
    if self:_crashify_call("print_property", "version publication",
                           "ModRelay:Version", version) then
        relay.crashify_version_published = true
    end
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
    if not self._crashify_disabled then
        self:_publish_version_property()
    end
end

function ModManager:_publish_mod_property(entry)
    if self._crashify_disabled then
        return
    end
    local name = entry and entry.name
    if _type(name) ~= "string" or name == "" or #name > MOD_NAME_MAX_BYTES
       or _string_find(name, "%c") then
        log("Crashify mod metadata skipped for entry id " .. safe_text(entry and entry.id)
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
        log("engine alert transport unavailable; failure notice will retry")
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

function ModManager:_call_teardown(entry, object, phase, ...)
    local args = pack(...)
    local ok, implemented, result = _xpcall(function()
        local callback = object[phase]
        if _type(callback) ~= "function" then
            return false, nil
        end
        return true, callback(object, _unpack(args, 1, args.n))
    end, protected_failure_detail)
    if not ok then
        log("mod '" .. display_name(entry and entry.name) .. "' " .. phase
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
        log("stale generation global retirement failed; cleanup remains best effort")
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

function ModManager:_handle_lifecycle_failure(entry, object, phase, detail)
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
        phase = phase,
        detail = detail,
        framework = framework,
    }

    if framework then
        self._generation_failed = true
        self._stop_load_pass = true
        self:_rebuild_framework_cleanup_queue(entry, object)
        log("framework-boundary lifecycle failure at entry '" .. display_name(entry.name)
            .. "' in generation " .. generation .. " during " .. phase
            .. "; Relay stopped the current generation:\n" .. detail)
        self:_attempt_alert("Mod Relay stopped the current mod generation after a framework-boundary error. "
            .. self:_alert_suffix())
    else
        self:_queue_cleanup(entry, object)
        log("mod '" .. display_name(entry.name) .. "' " .. phase
            .. " failed in generation " .. generation
            .. "; Relay disabled this entry:\n" .. detail)
        self:_attempt_alert("Mod Relay disabled mod '" .. display_name(entry.name)
            .. "' after a lifecycle error. " .. self:_alert_suffix())
    end
end

function ModManager:_call_outer(entry, object, phase, ...)
    local args = pack(...)
    local ok, implemented, result = _xpcall(function()
        local callback = object[phase]
        if _type(callback) ~= "function" then
            return false, nil
        end
        return true, callback(object, _unpack(args, 1, args.n))
    end, protected_failure_detail)
    if not ok then
        self:_handle_lifecycle_failure(entry, object, phase, safe_text(implemented))
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
        self:_begin_reload()
        self:_attempt_reminder_if_due(ALERT_REMINDER_SECONDS)
        return
    end

    if self._reload_in_progress then
        local target_generation = self._generation + 1
        local reload_data = self._reload_data
        self._load_target_generation = target_generation
        self._generation_failed = false
        self._stop_load_pass = false
        self._generation_globals_retired = false

        local load_ok, load_result = _pcall(function()
            return self:_load_all(reload_data)
        end)

        self._reload_data = nil
        self._reload_in_progress = false
        self._adapter:end_load_pass()
        self._load_target_generation = nil
        if not load_ok then
            log("hot reload load pass error: " .. safe_text(load_result))
            self._reload_degraded = true
        elseif load_result then
            self._reload_degraded = true
        end
        self._adapter:mark_load_done()
        self._generation = target_generation
        self:_prune_old_failure_records(target_generation)
        if self._reload_degraded then
            log("hot reload generation " .. self._generation
                .. " completed with errors; game restart recommended")
        else
            log("hot reload generation " .. self._generation .. " completed cleanly")
        end
        self._reload_degraded = false
        self:_drive_update(dt)
        self:_attempt_reminder_if_due(ALERT_REMINDER_SECONDS)
        return
    end

    if not self._mods_loaded then
        self._mods_loaded = true
        self._load_target_generation = 1
        self._generation_failed = false
        self._stop_load_pass = false
        self._generation_globals_retired = false
        self:_prepare_crashify_generation(false)
        local load_ok, load_result = _pcall(function()
            return self:_load_all(nil)
        end)
        self._adapter:end_load_pass()
        self._load_target_generation = nil
        self._generation = 1
        self._adapter:mark_load_done()
        if not load_ok then
            log("initial mod load pass error: " .. safe_text(load_result)
                .. "; initial generation finalized with errors")
        end
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
    log("hot reload requested (source: " .. safe_text(source) .. ")")
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
                log("reload shortcut unavailable (keyboard not ready); will retry")
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
            log("reload shortcut unavailable (keyboard query failed); will retry")
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
        log("mods.lst rescan error; loading empty mod set")
        self._reload_degraded = true
    elseif scan_had_order == false then
        self._reload_degraded = true
    end

    self._reload_data = reload_data
    self._reload_in_progress = true
end

function ModManager:_load_all(reload_data)
    local had_errors = false
    for idx, entry in _ipairs(self._mods) do
        if self._stop_load_pass then
            if entry.state == "not_loaded" then entry.state = "skipped" end
        else
            self._adapter:begin_load_entry(idx)
            if not self:_load_one(entry, reload_data) then
                had_errors = true
            end
            self:_drain_cleanup(false)
            if self._generation_failed then
                self:_drain_cleanup(false)
                self:_retire_generation_globals(false)
            end
        end
    end
    return had_errors or self._generation_failed
end

function ModManager:_fail_load_entry(entry, phase)
    if entry then
        entry.object = nil
        entry.state = "failed"
    end
    self:_log_dmf_framework_failure(entry, phase)
    return false
end

function ModManager:_load_one(entry, reload_data)
    local valid, reason = self._adapter:validate_entry(entry)
    if not valid then
        log("mod entry invalid (" .. safe_text(reason) .. "); skipped")
        return self:_fail_load_entry(entry, "entry invalid")
    end

    local name = entry.name
    local shown = display_name(name)
    local mod_data = Mods.file.exec_with_return(name .. "/" .. name .. ".mod")
    if mod_data == false then
        log("mod '" .. shown .. "' .mod missing or unreadable")
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
        log("mod '" .. shown .. "' .mod invalid (no run function)")
        return self:_fail_load_entry(entry, ".mod invalid")
    end

    self:_publish_mod_property(entry)
    local ok_run, object = _pcall(run_function)
    if not ok_run then
        log("mod '" .. shown .. "' run failed: " .. safe_text(object))
        return self:_fail_load_entry(entry, "run failed")
    end

    local result_type = _type(object)
    if object == nil then
        entry.state = "dmf_driven"
        log("mod '" .. shown .. "' DMF-driven (run returned no object)")
        return true
    end
    if result_type ~= "table" then
        -- Validate before assignment, member lookup, or value formatting.
        log("mod '" .. shown .. "' run returned invalid type " .. result_type)
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

function ModManager:_log_dmf_framework_failure(entry, phase)
    if entry and entry.name == "dmf" then
        log("!!! DMF FRAMEWORK LOAD FAILURE ('dmf' " .. phase
            .. "); load degraded — mods depending on DMF may not work !!!")
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
    if not self._adapter:is_load_done() then
        if not self._gsc_ignored_logged then
            log("on_game_state_changed ignored (reload/load in progress)")
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
