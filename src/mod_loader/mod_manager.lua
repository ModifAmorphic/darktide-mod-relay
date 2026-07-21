-- mod_manager.lua — the ModManager class (Relay's mod loader driver).
--
-- Loaded from the loader root via Mods.load_module("mod_manager") once class()
-- exists (the lifecycle bootstrap loads it inside the BootStateRequireGameScripts
-- wrapper). Defines class("ModManager") so DMF can find CLASS.ModManager.destroy
-- to hook (dmf_loader.lua).
--
-- This module is the GENERIC owner of:
--   - mods.lst scanning + the authoritative load order (_scan_mods, used by both
--     init and reload);
--   - the _mods collection + per-entry internal state/object bookkeeping;
--   - .mod execution, run()/init() per mod in order;
--   - the outer per-frame + state-change callback driving;
--   - reverse-order unload (destroy);
--   - per-mod pcall fault isolation;
--   - the hot-reload request/state machine, frame sequencing, reload-data
--     association, teardown/replacement ordering, and the keyboard trigger
--     plumbing (request_reload / _poll_reload_shortcut / _begin_reload).
--
-- Stock-DMF-specific integration — persisted manager-settings restoration,
-- DMF-visible field initialization/transitions, DMF-required entry-shape
-- validation, the file observer that drives IO adaptation, the eight
-- DMFMod:io_* overrides, generation-global retirement, and developer-mode
-- policy — lives in dmf_adapter.lua. The adapter writes the manager's
-- DMF-visible contract fields (_settings.developer_mode, _state,
-- _mod_load_index) through explicit transition methods, so this module never
-- touches them directly. See dmf_adapter.lua for the boundary.
--
-- SCAN/LOAD/RELOAD split:
--   - init()  SCANs only: reads mods.lst, builds the full _mods table (each
--             entry id/name/handle + internal state/object), and registers the
--             DMF IO observer via the adapter. No mod is loaded here; the order
--             file is authoritative (no DMF injection — DMF is first only
--             because the order file lists it first).
--   - update(dt)  the first call LOADs (per-mod run/init in order), then drives
--             each loaded mod's update. _state reaches "done" exactly once after
--             the pass (including empty/all-failed lists) — the manager decides
--             completion and asks the adapter to publish it.
--   - request_reload(source)  the trigger-neutral reload request seam. Validates
--             developer mode + done state + no stacking; records one request.
--             The keyboard poll feeds this seam; a future IPC could too (none
--             implemented now).
--
-- HOT RELOAD (developer-mode gated; LEFT Ctrl + LEFT Shift + R is the keyboard
-- trigger). Reload is destructive and non-transactional; no shadow load or
-- rollback. For an accepted request, the state machine spans two update frames:
--
--   Teardown frame (request consumed at update start, before normal updates):
--     1. adapter:mark_load_pending() — _state -> nil (no old callbacks after).
--     2. on_reload() forward order (pcall each); successful returns stored
--        keyed by mod NAME (nil is a valid lack of data); failure -> degraded.
--     3. on_unload() reverse order (pcall each), separately from on_reload;
--        failure -> degraded.
--     4. adapter:retire_stale_generation_globals() — retires old DMFMod (via
--        class_registry.retire_class) and clears new_mod/get_mod locally (NOT
--        CLASS/Managers.dmf/persistent_tables/require store).
--     5. drop old _mods; _scan_mods() rereads authoritative mods.lst (wrapped
--        so a rescan throw can't wedge; missing/unreadable -> empty + degraded).
--     6. mark replacement pending; RETURN (no updates this frame).
--
--   Replacement frame (next update):
--     7. _load_all(reload_data) under pcall — synchronous full pass in order;
--        for each outer object init(reload_data[name]) before the next entry
--        loads (startup/newly-added mods get nil). Per-mod failure isolated ->
--        degraded; a listed 'dmf' framework failure emits an unmistakable
--        framework log too. _reload_in_progress stays active until the protected
--        attempt finishes, then finalization ALWAYS runs regardless of a throw.
--     8. clear reload data; clear in-progress; clear _mod_load_index defensively
--        (end_load_pass); adapter:mark_load_done(); increment + report generation
--        (clean vs degraded, restart recommended on degraded); drive new updates
--        in that same completed frame. A later valid request stays possible.
--
-- While _state ~= "done" (initial load, teardown, or replacement pending), outer
-- on_game_state_changed callbacks are NOT driven (controlled single log). After
-- completion, new-generation callbacks work normally.
--
-- DMF reads three fields off Managers.mod: _mods[_mod_load_index].{id,name,
-- handle} during a mod's init, _state == "done" for its all_mods_loaded event,
-- and _settings.developer_mode for option registration. The adapter shapes these.

local _pcall = pcall
local _tostring = tostring
local _type = type
local _print = __print or print

-- Load the DMF adapter (a plain Lua module from the loader root). Required
-- before class("ModManager") so the adapter factory is in scope when instances
-- construct. The adapter holds no DMF-visible state of its own; it writes the
-- manager's contract fields through explicit transition methods.
--
-- mod_manager.lua and dmf_adapter.lua are co-staged loader-root modules (both
-- ship in bin/mod_loader/ via `make build`, both loaded via Mods.load_module).
-- A nil return here means the adapter source is missing or failed to parse/run
-- — i.e. a corrupt runtime bundle, not a recoverable runtime condition. No
-- fallback/duplicate logic is added: the lifecycle's existing mod_manager load
-- step (lifecycle.lua) treats a nil load result as "not yet loadable; retry,"
-- and its pcall around advance_bootstrap contains any parse/run failure to a
-- logged vanilla degradation rather than a boot crash.
local dmf_adapter = Mods.load_module("dmf_adapter")

local ModManager = class("ModManager")

local function log(msg)
    _print("[mod_loader] " .. msg)
end

-- ---------------------------------------------------------------------------
-- init — SCAN only.
-- ---------------------------------------------------------------------------
function ModManager:init()
    -- Establish the DMF-visible contract (publish Managers.mod; restore
    -- _settings from persistence; default state/index to nil) and register the
    -- DMF IO observer through the adapter. The adapter owns the DMF boundary.
    self._adapter = dmf_adapter.new(self)
    self._adapter:establish()
    self._adapter:register_io_observer()

    self._mods = {}
    self._mods_loaded = false
    self._generation = 0

    -- Reload request/state machine. _reload_requested is set by request_reload()
    -- and consumed at the start of the next update (one request, no stacking).
    -- _reload_in_progress marks the replacement-pending window (teardown done,
    -- load due next frame). _reload_degraded accumulates teardown+replacement
    -- errors for the completion log. _reload_data carries on_reload returns
    -- (keyed by name) into the replacement init() pass.
    self._reload_requested = false
    self._reload_in_progress = false
    self._reload_degraded = false
    self._reload_data = nil

    -- Keyboard trigger state. Button indexes are resolved lazily from update
    -- (keyboard availability at construction was not live-proven), cached after
    -- the first successful resolution, and re-resolved defensively if a later
    -- query throws so late availability can still work.
    self._kb_resolved = false
    self._kb_r = nil
    self._kb_lshift = nil
    self._kb_lctrl = nil
    self._kb_unavailable_logged = false

    -- on_game_state_changed ignored-state dedup (one log per not-done period).
    self._gsc_ignored_logged = false

    self:_scan_mods()
end

-- Scan mods.lst into a fresh _mods table. Authoritative: the loader injects
-- nothing (DMF is first only because the order file lists it first). Each entry
-- is shaped { id, name, handle, state, object }. Returns true on success
-- (including an intentionally empty list); returns false when mods.lst is
-- missing/unreadable (logged) so the caller can mark a reload degraded. Used by
-- both init() (startup, ignores the return) and _begin_reload() (reload).
function ModManager:_scan_mods()
    self._mods = {}
    local order = Mods.file.read_content_to_table("mods.lst")
    if _type(order) == "table" then
        for idx, name in ipairs(order) do
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
    -- false (missing/unreadable) or any unexpected non-table.
    log("mods.lst missing or unreadable; no mods will load")
    return false
end

-- ---------------------------------------------------------------------------
-- update — poll reload trigger, run the reload state machine, LOAD on the first
-- call, then drive per-frame callbacks.
-- ---------------------------------------------------------------------------
function ModManager:update(dt)
    -- Poll the keyboard trigger from the update path (feeds request_reload;
    -- request_reload enforces developer_mode + done + no-stacking).
    self:_poll_reload_shortcut()

    -- Reload request: consume one at the start, before normal outer updates.
    -- request_reload only sets the flag when it validated, so this is the
    -- teardown-frame entry point.
    if self._reload_requested then
        self._reload_requested = false
        self:_begin_reload()
        return -- teardown frame: no old updates, no new loads this frame
    end

    -- Replacement load pending: teardown completed last frame. Load the full
    -- new generation synchronously, then drive new-generation updates in this
    -- same completed frame. The load pass itself is pcall-protected so an
    -- unexpected throw can't wedge finalization: _reload_in_progress stays
    -- semantically active until the protected attempt finishes, then
    -- _reload_data/_reload_in_progress/_mod_load_index/_state ALWAYS settle
    -- (regardless of throw), the generation is reported (degraded on a throw),
    -- and a later reload request stays possible. No transactional rollback.
    if self._reload_in_progress then
        local reload_data = self._reload_data
        local load_ok, load_result = _pcall(function()
            return self:_load_all(reload_data)
        end)
        -- ALWAYS finalize, whether _load_all returned normally or threw.
        self._reload_data = nil
        self._reload_in_progress = false
        -- _load_all clears _mod_load_index itself on a clean return; a throw
        -- may leave it set, so clear defensively so DMF-visible state settles.
        self._adapter:end_load_pass()
        if not load_ok then
            log("hot reload load pass error: " .. _tostring(load_result))
            self._reload_degraded = true
        elseif load_result then
            -- _load_all returned had_errors == true (a per-mod failure).
            self._reload_degraded = true
        end
        self._adapter:mark_load_done()
        self._generation = self._generation + 1
        if self._reload_degraded then
            log("hot reload generation " .. self._generation
                .. " completed with errors; game restart recommended")
        else
            log("hot reload generation " .. self._generation .. " completed cleanly")
        end
        self._reload_degraded = false
        self:_drive_update(dt)
        return
    end

    -- Initial load (first update ever): one-pass load, then drive updates.
    if not self._mods_loaded then
        self._mods_loaded = true
        self:_load_all(nil) -- startup init receives nil reload data
        self._generation = 1
        self._adapter:mark_load_done()
    end

    self:_drive_update(dt)
end

-- ---------------------------------------------------------------------------
-- Reload request seam (trigger-neutral).
--
-- Validates and records a reload request. Requires adapter-reported developer
-- mode, manager fully loaded (_state == "done"), and no request/in-progress
-- reload already active. Rejects WITHOUT mutating the active runtime. Returns
-- (true) on accepted or (false, reason) on rejected — usable by tests and any
-- future caller (IPC is out of scope here). A request while loading, tearing
-- down, or already requested/in progress is rejected (no stacking).
-- ---------------------------------------------------------------------------
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
    log("hot reload requested (source: " .. _tostring(source) .. ")")
    return true
end

-- Poll the keyboard reload shortcut from the update path and feed acceptance
-- through request_reload("keyboard"). Exact established parity: the shortcut is
-- Keyboard.pressed(button_index("r")) AND the numeric sum
-- Keyboard.button(button_index("left shift")) + Keyboard.button(button_index
-- ("left ctrl")) == 2 (both LEFT modifiers held).
--
-- Button indexes are resolved lazily + defensively from update (not
-- construction). Missing/invalid/throwing Keyboard APIs/indexes are treated as
-- "reload unavailable": no update failure, a single controlled log per
-- unavailable condition (reset on recovery), and the manager keeps retrying so
-- late availability can work. Developer mode false/default does not trigger.
function ModManager:_poll_reload_shortcut()
    if not self._kb_resolved then
        local ok = _pcall(function()
            local kb = Keyboard
            if _type(kb) ~= "table" then
                error("Keyboard unavailable")
            end
            local r = kb.button_index("r")
            local ls = kb.button_index("left shift")
            local lc = kb.button_index("left ctrl")
            if _type(r) ~= "number" or _type(ls) ~= "number" or _type(lc) ~= "number" then
                error("button_index returned non-number")
            end
            self._kb_r = r
            self._kb_lshift = ls
            self._kb_lctrl = lc
        end)
        if not ok then
            if not self._kb_unavailable_logged then
                log("reload shortcut unavailable (keyboard not ready); will retry")
                self._kb_unavailable_logged = true
            end
            return
        end
        self._kb_resolved = true
        -- NOTE: do not reset _kb_unavailable_logged here. The query below may
        -- still throw (e.g. pressed/button absent while button_index works);
        -- resetting eagerly would re-log every frame. The flag resets only after
        -- a fully successful query.
    end

    -- Query the exact parity condition (defensively). A throw here forces a
    -- re-resolution next frame so late/transient failures can recover.
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
        return
    end
    self._kb_unavailable_logged = false
    if pressed and mod_sum == 2 then
        self:request_reload("keyboard")
    end
end

-- ---------------------------------------------------------------------------
-- Reload teardown frame: callbacks -> retire -> rescan -> mark pending.
--
-- Runs entirely inside update() right after a request is consumed. No old-
-- generation update or state-change callback may run after this begins (the
-- caller returns immediately after). Best-effort and non-transactional: errors
-- mark the reload degraded but never wedge the state machine. Finalization is
-- guaranteed in TWO protected places (neither offers rollback/shadow loading):
--   - here, the teardown/rescan is pcall-protected so an on_reload/on_unload
--     throw or a mods.lst read error can't escape — _mods ends up empty and the
--     reload completes degraded; and
--   - in update(), the replacement-load pass (_load_all) is itself pcall-
--     protected so an unexpected throw there also settles _reload_data/
--     _reload_in_progress/_mod_load_index/_state and reports the generation.
-- After either kind of failure a later valid reload request remains possible.
-- ---------------------------------------------------------------------------
function ModManager:_begin_reload()
    -- Transition _state away from done (nil-before-done contract) and reset the
    -- degraded accumulator for this generation.
    self._adapter:mark_load_pending()
    self._reload_degraded = false

    local old_mods = self._mods

    -- on_reload() forward load order. Store only successful return values keyed
    -- by stable mod NAME (never numeric position). Nil is a valid lack of data.
    -- A mod without on_reload contributes nothing (nil on lookup). A failing
    -- on_reload logs the mod + phase and marks degraded; its data is absent.
    local reload_data = {}
    for i = 1, #old_mods do
        local entry = old_mods[i]
        local obj = entry.object
        if obj and _type(obj.on_reload) == "function" then
            local ok, ret = _pcall(function()
                return obj:on_reload()
            end)
            if ok then
                reload_data[entry.name] = ret
            else
                log("mod '" .. entry.name .. "' on_reload failed: " .. _tostring(ret))
                self._reload_degraded = true
            end
        end
    end

    -- on_unload() reverse load order, separately from on_reload. Failure logs
    -- and marks degraded; reverse teardown continues.
    for i = #old_mods, 1, -1 do
        local entry = old_mods[i]
        local obj = entry.object
        if obj and _type(obj.on_unload) == "function" then
            local ok, err = _pcall(function()
                obj:on_unload()
            end)
            if not ok then
                log("mod '" .. entry.name .. "' on_unload failed: " .. _tostring(err))
                self._reload_degraded = true
            end
        end
    end

    -- Retire stale stock-DMF generation globals (DMFMod/new_mod/get_mod) after
    -- the callbacks, before the new DMF scripts re-execute. Does NOT clear
    -- CLASS/Managers.dmf/persistent_tables/require store/Relay globals.
    self._adapter:retire_stale_generation_globals()

    -- Reread authoritative mods.lst into a fresh _mods. _scan_mods clears
    -- _mods FIRST, so a throw from the read after it begins still leaves _mods
    -- empty; the pcall contains it so the reload completes degraded rather than
    -- wedging. (No separate pre-clear — _scan_mods already does it.) The loader
    -- still injects nothing — DMF loads only if listed.
    local scan_ok, scan_had_order = _pcall(function()
        return self:_scan_mods()
    end)
    if not scan_ok then
        log("mods.lst rescan error; loading empty mod set")
        self._reload_degraded = true
    elseif scan_had_order == false then
        -- _scan_mods already logged the missing/unreadable order.
        self._reload_degraded = true
    end

    self._reload_data = reload_data
    self._reload_in_progress = true
end

-- Load every scanned mod in order. Per-mod: set _mod_load_index (via adapter),
-- load <name>/<name>.mod, validate run(), pcall run, and if an object is
-- returned pcall its init(reload_data_for_name) BEFORE the next mod loads. A nil
-- object is a successful DMF-managed mod (driven by DMF's inner loop, not the
-- outer driver). Returns true if the pass had ANY per-mod error (false if all
-- entries loaded cleanly) — so the reload caller can mark the generation
-- degraded. _mod_load_index is cleared (via adapter) after the loop. reload_data
-- is nil for the startup pass and a name-keyed table for a reload pass (lookup
-- yields nil for newly-added/renamed mods — correct).
function ModManager:_load_all(reload_data)
    local had_errors = false
    for idx, entry in ipairs(self._mods) do
        self._adapter:begin_load_entry(idx)
        if not self:_load_one(entry, reload_data) then
            had_errors = true
        end
    end
    self._adapter:end_load_pass()
    return had_errors
end

function ModManager:_load_one(entry, reload_data)
    -- Validate the DMF-required entry shape at the load boundary before any
    -- mod runs (the adapter centralizes this; a malformed entry is logged +
    -- skipped). Scan always produces well-formed entries, so this is a
    -- defensive no-op on the happy path.
    local ok, reason = self._adapter:validate_entry(entry)
    if not ok then
        log("mod entry invalid (" .. _tostring(reason) .. "); skipped")
        self:_log_dmf_framework_failure(entry, "entry invalid")
        return false
    end
    local name = entry.name
    local mod_data = Mods.file.exec_with_return(name .. "/" .. name .. ".mod")
    if mod_data == false then
        log("mod '" .. name .. "' .mod missing or unreadable")
        self:_log_dmf_framework_failure(entry, ".mod missing/unreadable")
        return false
    end
    if _type(mod_data) ~= "table" or _type(mod_data.run) ~= "function" then
        log("mod '" .. name .. "' .mod invalid (no run function)")
        self:_log_dmf_framework_failure(entry, ".mod invalid")
        return false
    end
    local ok_run, obj = _pcall(mod_data.run)
    if not ok_run then
        log("mod '" .. name .. "' run failed: " .. _tostring(obj))
        self:_log_dmf_framework_failure(entry, "run failed")
        return false
    end
    if obj == nil then
        -- DMF-managed mod: run() returned nothing for its side effect
        -- (registered itself via new_mod). Success, not outer-driven.
        entry.state = "dmf_driven"
        log("mod '" .. name .. "' DMF-driven (run returned no object)")
        return true
    end
    entry.object = obj
    entry.state = "running"
    if _type(obj.init) == "function" then
        -- reload_data is nil on startup; lookup yields nil for newly-added or
        -- renamed mods (correct: they receive nil, just like startup).
        local data = reload_data and reload_data[name]
        local iok, ierr = _pcall(function()
            obj:init(data)
        end)
        if not iok then
            log("mod '" .. name .. "' init failed: " .. _tostring(ierr))
            self:_log_dmf_framework_failure(entry, "init failed")
            -- Failed/partially initialized: not driven each frame.
            entry.object = nil
            entry.state = "failed"
            return false
        end
    end
    return true
end

-- Emit an unmistakable DMF framework-load failure in addition to the normal
-- per-phase diagnostics, when the listed 'dmf' entry fails during a load pass.
-- Isolation continues regardless (the caller logs + skips). No-op for any other
-- entry name. Only meaningful during reload (startup DMF failure is already a
-- clear vanilla-degradation), but harmless either way.
function ModManager:_log_dmf_framework_failure(entry, phase)
    if entry and entry.name == "dmf" then
        log("!!! DMF FRAMEWORK LOAD FAILURE ('dmf' " .. phase
            .. "); reload degraded — mods depending on DMF may not work !!!")
    end
end

function ModManager:_drive_update(dt)
    for _, entry in ipairs(self._mods) do
        local obj = entry.object
        if obj and _type(obj.update) == "function" then
            local ok, err = _pcall(function()
                obj:update(dt)
            end)
            if not ok then
                log("mod '" .. entry.name .. "' update failed: " .. _tostring(err))
            end
        end
    end
end

-- Called by the GameStateMachine wrapper. Forwards status + state name +
-- state object verbatim to each outer-driven mod's callback. While the manager
-- is not done (initial loading, reload teardown, or replacement pending), outer
-- state-change callbacks are NOT driven — a controlled single log per not-done
-- period avoids spam. After completion, new-generation callbacks work normally.
function ModManager:on_game_state_changed(status, state_name, state_object)
    if not self._adapter:is_load_done() then
        if not self._gsc_ignored_logged then
            log("on_game_state_changed ignored (reload/load in progress)")
            self._gsc_ignored_logged = true
        end
        return
    end
    self._gsc_ignored_logged = false
    for _, entry in ipairs(self._mods) do
        local obj = entry.object
        if obj and _type(obj.on_game_state_changed) == "function" then
            local ok, err = _pcall(function()
                obj:on_game_state_changed(status, state_name, state_object)
            end)
            if not ok then
                log("mod '" .. entry.name .. "' on_game_state_changed failed: " .. _tostring(err))
            end
        end
    end
end

-- destroy — DMF hooks this (dmf_loader.lua: CLASS.ModManager.destroy). Calls
-- on_unload on each outer-driven mod that has one, pcall-guarded, reverse
-- order (most recently loaded first — mirrors typical unload expectations).
-- After a successful or failed reload, _mods holds only the current/new
-- generation (old objects were unloaded in the teardown frame), so destroy()
-- never double-unloads old objects.
function ModManager:destroy()
    for i = #self._mods, 1, -1 do
        local entry = self._mods[i]
        local obj = entry.object
        if obj and _type(obj.on_unload) == "function" then
            local ok, err = _pcall(function()
                obj:on_unload()
            end)
            if not ok then
                log("mod '" .. entry.name .. "' on_unload failed: " .. _tostring(err))
            end
        end
    end
end

return ModManager
