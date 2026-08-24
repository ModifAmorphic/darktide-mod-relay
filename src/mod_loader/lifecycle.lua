-- lifecycle.lua — the bootstrap coordinator + retryable boot wrapper.
--
-- Mods.coordinate_bootstrap runs after every require (via require_bridge) and
-- advances two idempotent steps: install the class registry once `class` is a
-- function, and wrap BootStateRequireGameScripts._state_update once it exists.
-- That boot wrapper calls the original first, then a protected
-- advance_bootstrap retrying only the missing steps — load the manager
-- (built-in or the configured RELAY_MOD_MANAGER alternate), the chassis
-- duties, the engine wraps (StateGame.update, GameStateMachine
-- _change_state/.destroy, opt-in StateSplash skip) — until a `completed`
-- flag short-circuits.
--
-- Full contract (deferred bootstrap, the exact-once state-exit dedup, the
-- GameStateMachine read-only rule, the alternate-manager failure policy):
-- docs/architecture/MOD_LOADER-DMF.md + docs/reference/relay/manager-slot.md.

local _pcall = pcall
local _tostring = tostring
local _unpack = unpack
local _select = select
local _rawget = rawget
local _type = type
local _string_find = string.find

-- Leveled diagnostics (init.lua publishes the helper on Mods._relay before this
-- module loads). frame_stamp appends the combined tick/frame correlation stamp
-- to the state-dispatch lines (tick = loader-relative engine updates since
-- injection, primary; FRAME_INDEX secondary — see
-- docs/reference/relay/logging.md); _tick_bump advances the counter at each
-- observed engine update boundary. display_text safely renders the
-- interpolated state names (pcall'd, scrubbed, capped — a raising __tostring
-- can never throw out of a dispatch line).
local log_info  = Mods._relay.log_info
local log_debug = Mods._relay.log_debug
local log_warn  = Mods._relay.log_warn
local log_error = Mods._relay.log_error
local frame_stamp = Mods._relay.frame_stamp
local display_text = Mods._relay.display_text
local _tick_bump = Mods._relay._tick_bump

-- ---------------------------------------------------------------------------
-- Throttled containment-error logging for the five chassis containment sites
-- (Step-2 update, Step-3 exit/enter dispatches, Step-4 final exit, and the
-- boot wrapper's advance_bootstrap containment). NEVER log-once-and-swallow:
-- the first occurrence per (site, error) key logs immediately; without a
-- usable clock the helper degrades to logging every occurrence. Full policy
-- (keying, recurrence window + count suffix, key cap):
-- docs/architecture/MOD_LOADER-DMF.md → "Deferred bootstrap".
-- ---------------------------------------------------------------------------
local _THROTTLE_INTERVAL_S = 10
local _THROTTLE_MAX_KEYS = 32
local _throttle_entries = {}
local _throttle_key_count = 0

local function log_contained_error(prefix, err)
    local text = _tostring(err)
    local now = nil
    local lua_surface = (_type(Mods) == "table") and Mods.lua or nil
    local os_surface = (_type(lua_surface) == "table") and lua_surface.os or nil
    if _type(os_surface) == "table" and _type(os_surface.time) == "function" then
        local ok, t = _pcall(os_surface.time)
        if ok and _type(t) == "number" then
            now = t
        end
    end
    if now == nil then
        log_error(prefix .. text)
        return
    end
    local entry = _throttle_entries[prefix .. "\0" .. text]
    if entry == nil then
        if _throttle_key_count >= _THROTTLE_MAX_KEYS then
            _throttle_entries = {}
            _throttle_key_count = 0
            log_debug("containment error throttle table reset (" .. _THROTTLE_MAX_KEYS
                .. "+ distinct errors); recurrence counts start fresh")
        end
        _throttle_entries[prefix .. "\0" .. text] = { last = now, suppressed = 0 }
        _throttle_key_count = _throttle_key_count + 1
        log_error(prefix .. text)
        return
    end
    if now - entry.last >= _THROTTLE_INTERVAL_S then
        log_error(prefix .. text .. " [x" .. (entry.suppressed + 1)
            .. " in the last " .. _THROTTLE_INTERVAL_S .. "s]")
        entry.last = now
        entry.suppressed = 0
    else
        entry.suppressed = entry.suppressed + 1
    end
end

-- Load dmf_adapter exactly ONCE per process (module scope) and publish it on
-- Mods._relay.dmf_adapter. Mods.load_module re-runs a chunk on every call, so
-- a second load would create an independent module table (and, via its
-- factories, a second io observer). mod_manager reads the published table at
-- init time; on failure nothing is published and manager creation fails
-- clearly per-tick (corrupted-install semantics unchanged).
do
    local loader = Mods and Mods.load_module
    if _type(loader) == "function" then
        local ok, adapter_module = _pcall(loader, "dmf_adapter")
        if ok and _type(adapter_module) == "table" then
            Mods._relay.dmf_adapter = adapter_module
        end
    end
end

-- Process-lifetime Crashify version publication (chassis-owned). Attempted
-- once at manager creation (Step 1c) and retried opportunistically by the
-- StateGame.update wrap until success — Crashify may appear (or recover) late.
-- Absence/throw never breaks bootstrap or update (fully pcall-contained); each
-- failure case logs once. The crashify_version_published guard lives on
-- Mods._relay (chassis-owned state, same field the manager used previously).
local _CRASHIFY_VERSION_MAX_BYTES = 128
local _version_invalid_logged = false
local _version_unavailable_logged = false
local _version_publish_failed_logged = false

local function _publish_crashify_version()
    local relay = (_type(Mods) == "table") and _rawget(Mods, "_relay") or nil
    if _type(relay) == "table" and relay.crashify_version_published == true then
        return
    end
    local version = (_type(relay) == "table") and _rawget(relay, "version") or nil
    if _type(version) ~= "string" or version == "" or #version > _CRASHIFY_VERSION_MAX_BYTES
       or _string_find(version, "%c") then
        if not _version_invalid_logged then
            log_debug("Relay version crash metadata unavailable (missing or invalid private build value)")
            _version_invalid_logged = true
        end
        return
    end
    local ok, published = _pcall(function()
        local crashify = _rawget(_G, "Crashify")
        if _type(crashify) ~= "table" or _type(crashify.print_property) ~= "function" then
            return false
        end
        crashify.print_property("ModRelay:Version", version)
        return true
    end)
    if ok and published then
        if _type(relay) == "table" then
            relay.crashify_version_published = true
        end
        return
    end
    if not ok then
        if not _version_publish_failed_logged then
            log_warn("Crashify version publication failed; will retry")
            _version_publish_failed_logged = true
        end
    elseif not _version_unavailable_logged then
        log_debug("Crashify unavailable; version crash metadata will retry")
        _version_unavailable_logged = true
    end
end

-- Snapshot the StateSplash skip ONCE at module-eval time (init.lua stored it in
-- Mods._relay.skip_splash). Nil-safe. When true, advance_bootstrap gains a 5th
-- idempotent step that wraps CLASS.StateSplash.on_enter.
local _skip_splash_enabled = Mods and Mods._relay and Mods._relay.skip_splash == true

-- Snapshot the alternate mod manager path ONCE at module-eval time (init.lua
-- published it as Mods._relay.mod_manager_path from the trampoline-baked
-- RELAY_MOD_MANAGER global). A non-empty string means Step 1a loads the class
-- from that EXACT path (verbatim, never rooted); anything else (nil / "" /
-- non-string) is the built-in path, byte-identical to before. Selection +
-- failure policy: docs/architecture/MOD_LOADER-DMF.md → "The manager slot".
local _alternate_manager_path = nil
do
    local relay = Mods and Mods._relay
    local configured = (_type(relay) == "table") and relay.mod_manager_path or nil
    if _type(configured) == "string" and configured ~= "" then
        _alternate_manager_path = configured
    end
end

-- Resolve StateTitle (StateSplash's _next_state) via the engine's require. It's
-- cached in package.loaded by the time StateSplash is entered. Resolved lazily
-- on the first on_enter and cached. Returns nil + logs once if unavailable
-- (engine contract shift → vanilla splash fallback).
local _state_title = nil
local _state_title_resolved = false
local function _resolve_state_title()
    if _state_title_resolved then return _state_title end
    _state_title_resolved = true
    local req = Mods and Mods.original_require
    if _type(req) == "function" then
        local ok, result = _pcall(req, "scripts/game_states/game/state_title")
        if ok and _type(result) == "table" then
            _state_title = result
            return _state_title
        end
    end
    log_warn("splash skip: StateTitle unavailable; vanilla splash will run")
    return nil  -- cached nil
end

-- Pack varargs preserving the count (incl. embedded/trailing nils). LuaJIT 2.1
-- has no table.pack; the count is the upper bound when unpacking. Used by
-- wrappers that do work after the original returns (so they cannot tail-call).
local function _pack(...)
    return { n = _select("#", ...), ... }
end

-- Per-state-machine side-track of the last state object that received an exit
-- dispatch. Identity-compared so exactly-one exit per state object: a state
-- exited by _change_state is not redispatched by destroy, and vice versa.
-- Weak-keyed so destroyed state machines don't pin memory. Module-private.
local _last_exited = setmetatable({}, { __mode = "k" })

-- Claim the exit of `state` on `gsm`: returns true + records it if not already
-- last-exited; false (no-op) if it was. Called only when a manager exists and
-- the exit will dispatch, so a nil-manager transition (boot) does not suppress
-- a later destroy-time dispatch.
local function _claim_exit(gsm, state)
    if _last_exited[gsm] == state then
        return false
    end
    _last_exited[gsm] = state
    return true
end

-- Retryable bootstrap state. Each step is independently idempotent; a partial
-- pass does not prevent a later pass from finishing. Once all steps complete,
-- `completed` short-circuits later calls.
local bs = {
    boot_wrapped = false,
    completed = false,
    -- manager step (load + create + chassis duties are separately idempotent)
    manager_class = nil,
    manager_class_loaded = false,
    manager_created = false,
    manager_missing_logged = false,
    -- alternate-manager failure modes already logged (a set; tracked
    -- separately from the built-in's manager_missing_logged and used only
    -- when an alternate is configured)
    alternate_failure_logged = {},
    -- chassis-duties step (Step 1c): establish + observer + version attempt.
    -- chassis_adapter retains the chassis-constructed adapter instance (the
    -- alternate-manager path) so a failed-then-retried pass reuses it instead
    -- of registering a second io observer.
    chassis_duties_done = false,
    chassis_adapter = nil,
    -- state-game step
    state_game_wrapped = false,
    state_game_missing_logged = false,
    -- change-state step
    change_state_wrapped = false,
    change_state_missing_logged = false,
    -- destroy step (final state-exit dispatch before destruction)
    destroy_wrapped = false,
    destroy_missing_logged = false,
    -- tick-driver step (CLASS.StateBoot.update wrap, installed by the
    -- coordinator the moment the class appears — see coordinate_bootstrap)
    tick_boot_wrapped = false,
    -- splash-skip step (opt-in; only attempted when _skip_splash_enabled)
    splash_wrapped = false,
    splash_missing_logged = false,
}

-- ---------------------------------------------------------------------------
-- Alternate mod manager (RELAY_MOD_MANAGER) — permanent-failure handling.
-- A configured alternate is a hard operator commitment: failures retry
-- through the normal bootstrap machinery only while the engine is not yet
-- ready; once ready, a failure is permanent (never a managerless game).
-- Normative failure policy: docs/reference/relay/manager-slot.md.
-- ---------------------------------------------------------------------------

-- Engine-ready: every manager-independent bootstrap step (2-4) is wrapped.
-- The pass that completes those steps runs them AFTER step 1, so a failing
-- step-1/1b pass always retries at least once before this gate can be
-- satisfied (a natural two-attempt minimum).
local function _engine_ready()
    return bs.state_game_wrapped and bs.change_state_wrapped and bs.destroy_wrapped
end

-- Terminate the process: log the final ERROR first (naming the configured
-- path, the failure, and the policy), then exit via the first workable
-- surface — ffi.C.ExitProcess(1) (cdef'd once; re-cdef is legal in LuaJIT so
-- the guard is efficiency-only; x64 has a single calling convention),
-- os.exit(1), or a contained raise if neither works. ffi/os are read from
-- Mods.lua at CALL time (so a test sandbox can mock them). The helper is
-- double-invocation guarded — the first call wins; later calls are silent
-- no-ops (no exit surface re-invoked, nothing logged).
local _hard_exit_attempted = false
local _exit_cdef_attempted = false

-- The real engine's ffi.C (the LuaJIT C namespace) is a userdata cdata
-- object, NOT a table; test sandboxes mock it as a table. The exit branch
-- must accept both shapes — a table-only check silently disables it in
-- production (every exit would fall through to the os fallback).
local function _ffi_c_usable(c)
    local c_type = _type(c)
    return c_type == "userdata" or c_type == "table"
end

local function _hard_exit(failure)
    if _hard_exit_attempted then
        return
    end
    _hard_exit_attempted = true
    log_error("Relay is exiting: an alternate mod manager is configured ("
        .. _alternate_manager_path
        .. ") and the game must not continue without it. Final failure: " .. failure)
    local lua_surface = (_type(Mods) == "table") and Mods.lua or nil
    local ffi = (_type(lua_surface) == "table") and lua_surface.ffi or nil
    if _type(ffi) == "table" and _ffi_c_usable(ffi.C) and _type(ffi.cdef) == "function" then
        if not _exit_cdef_attempted then
            _exit_cdef_attempted = true
            _pcall(ffi.cdef, "void ExitProcess(unsigned int);")
        end
        if _pcall(function() ffi.C.ExitProcess(1) end) then
            return
        end
    end
    local os_surface = (_type(lua_surface) == "table") and lua_surface.os or nil
    if _type(os_surface) == "table" and _type(os_surface.exit) == "function" then
        if _pcall(os_surface.exit, 1) then
            return
        end
    end
    error("Relay could not terminate the process (no usable ffi/os exit surface); "
        .. "underlying failure: " .. failure, 0)
end

-- Record one alternate-manager failure: log once per distinct mode (the
-- configured path is in the message), then apply the engine-ready gate —
-- not ready yet -> the failure simply retries through the existing machinery
-- on the next pass; ready -> permanent -> terminate.
local function _alternate_manager_failed(mode, detail)
    if not bs.alternate_failure_logged[mode] then
        bs.alternate_failure_logged[mode] = true
        log_warn("bootstrap: alternate mod manager failed (" .. detail .. ") at "
            .. _alternate_manager_path .. "; will retry until the engine is ready")
    end
    if _engine_ready() then
        _hard_exit(detail)
    end
end

-- ---------------------------------------------------------------------------
-- advance_bootstrap — attempts only missing steps (each independently
-- idempotent). Called protected after every _state_update.
-- ---------------------------------------------------------------------------
local function advance_bootstrap()
    if bs.completed then
        return
    end

    -- Step 1a: load the manager class (idempotent). Built-in: from the loader
    --    root. Alternate (a non-empty RELAY_MOD_MANAGER was baked): from that
    --    EXACT path via the raw-io chunk helper — verbatim, never rooted —
    --    and the chunk must return a table (the class). Alternate failures
    --    log once per distinct mode and, once the engine is ready, terminate
    --    the process (see _alternate_manager_failed).
    if not bs.manager_class_loaded then
        local ModManager
        if _alternate_manager_path then
            local load_chunk = Mods and Mods._relay and Mods._relay.load_chunk
            if _type(load_chunk) ~= "function" then
                _alternate_manager_failed("helper",
                    "the loader chunk helper is unavailable (corrupted install?)")
            else
                -- Protected so even a raising seam stays inside the gate (a
                -- tracked failure, never an unbounded managerless retry).
                local pok, ok, result, mode = _pcall(load_chunk, _alternate_manager_path)
                if pok and ok and _type(result) == "table" then
                    ModManager = result
                elseif pok and ok then
                    _alternate_manager_failed("return", "chunk did not return a class table")
                elseif pok then
                    local load_mode = mode or "run"
                    _alternate_manager_failed(load_mode, "chunk load failed (" .. load_mode .. ")")
                else
                    _alternate_manager_failed("seam",
                        "the chunk seam raised: " .. _tostring(ok))
                end
            end
        else
            ModManager = Mods.load_module("mod_manager")
        end
        if ModManager then
            bs.manager_class = ModManager
            bs.manager_class_loaded = true
        elseif not _alternate_manager_path then
            if not bs.manager_missing_logged then
                log_debug("bootstrap: mod_manager not yet loadable; will retry")
                bs.manager_missing_logged = true
            end
        end
    end

    -- Step 1b: instantiate Managers.mod exactly once. Separate from the load so
    --    a load that succeeds but a :new() that raises can retry creation
    --    without re-loading. Under an alternate, :new() is contained + tracked
    --    (a class that cannot instantiate is broken, not early): a raise or a
    --    nil instance is a failure through the same engine-ready gate; before
    --    ready it simply retries. The built-in branch is unchanged: an error
    --    escapes to the boot wrapper's containment, creation retries next tick.
    if bs.manager_class_loaded and not bs.manager_created then
        if _alternate_manager_path then
            if not (Managers and Managers.mod) then
                Managers = Managers or {}
                local ok, instance = _pcall(function()
                    return bs.manager_class:new()
                end)
                if ok and instance ~= nil then
                    Managers.mod = instance
                else
                    _alternate_manager_failed("new", ok
                        and ":new() returned no instance"
                        or (":new() raised: " .. _tostring(instance)))
                end
            end
            if Managers and Managers.mod then
                bs.manager_created = true
                log_debug("bootstrap: manager created")
            end
        else
            Managers = Managers or {}
            if not Managers.mod then
                Managers.mod = bs.manager_class:new()
            end
            bs.manager_created = true
            log_debug("bootstrap: manager created")
        end
    end

    -- Step 1c: manager-agnostic chassis duties, once after creation: resolve
    --    the ONE registering dmf_adapter instance (the manager's own
    --    _adapter when compatible — the built-in path; else a chassis-
    --    constructed instance retained for the process), establish(), the io
    --    observer, and the Crashify version attempt. A failure raises to the
    --    boot wrapper's containment and retries next tick. Detail:
    --    MOD_LOADER-DMF.md → "Chassis duties (Step 1c)".
    if bs.manager_created and not bs.chassis_duties_done then
        local m = Managers and Managers.mod
        local adapter = nil
        local own = (_type(m) == "table") and _rawget(m, "_adapter") or nil
        if _type(own) == "table"
           and _type(own.establish) == "function"
           and _type(own.register_io_observer) == "function" then
            adapter = own
        else
            adapter = bs.chassis_adapter
            if adapter == nil then
                local adapter_module = Mods and Mods._relay and _rawget(Mods._relay, "dmf_adapter")
                if _type(adapter_module) ~= "table" or _type(adapter_module.new) ~= "function" then
                    error("dmf_adapter module unavailable on Mods._relay (corrupted install?)")
                end
                adapter = adapter_module.new(m)
                bs.chassis_adapter = adapter
            end
        end
        adapter:establish()
        adapter:register_io_observer()
        _publish_crashify_version()
        bs.chassis_duties_done = true
    end

    -- Step 2: wrap CLASS.StateGame.update so Managers.mod:update(dt) runs BEFORE
    --    the engine update (mods see pre-frame state). Reads Managers.mod at
    --    call time, so installing before the manager exists is harmless.
    --    This wrap is also the post-boot half of the tick observation chain:
    --    the entry bump (the Main.update boundary) continues the count the
    --    StateBoot.update wrap started — the GSM runs exactly one
    --    current-state update per engine update, so the two wraps never both
    --    fire in one update (no double increment).
    if not bs.state_game_wrapped then
        local sg = CLASS and _rawget(CLASS, "StateGame")
        if sg and _type(sg.update) == "function" then
            local orig_update = sg.update
            sg.update = function(self, dt, ...)
                _tick_bump()
                local m = Managers and Managers.mod
                if m then
                    -- Opportunistic version-publication retry (cheap flag
                    -- check; contained). Short-circuits for the process
                    -- lifetime once the property is published.
                    _publish_crashify_version()
                    local ok, err = _pcall(function()
                        m:update(dt)
                    end)
                    if not ok then
                        log_contained_error("Managers.mod:update failed: ", err)
                    end
                end
                return orig_update(self, dt, ...)
            end
            bs.state_game_wrapped = true
            log_debug("bootstrap: StateGame.update wrapped")
        else
            if not bs.state_game_missing_logged then
                log_debug("bootstrap: CLASS.StateGame.update not yet available; will retry")
                bs.state_game_missing_logged = true
            end
        end
    end

    -- Step 3: wrap CLASS.GameStateMachine._change_state. Dispatch "exit" before
    --    the transition and "enter" after it. Outgoing/incoming states are READ
    --    from self._state (captured before/after the original) via
    --    current_state_name(); this wrapper never writes a state field. Exit is
    --    deduped against the destroy wrapper via _claim_exit.
    if not bs.change_state_wrapped then
        local gsm = CLASS and _rawget(CLASS, "GameStateMachine")
        if gsm and _type(gsm._change_state) == "function" then
            local orig_change = gsm._change_state
            gsm._change_state = function(self, ...)
                local m = Managers and Managers.mod
                -- Capture the outgoing state BEFORE the original runs. Gate the
                -- dispatch on: current state present, current_state_name()
                -- available, manager exists, and not already exited (dedup
                -- shared with the destroy wrapper).
                local old_state = self._state
                if old_state ~= nil
                   and _type(self.current_state_name) == "function"
                   and m and _claim_exit(self, old_state) then
                    local old_name = self:current_state_name()
                    local ok, err = _pcall(function()
                        m:on_game_state_changed("exit", old_name, old_state)
                    end)
                    if not ok then
                        log_contained_error("state exit drive failed: ", err)
                    else
                        log_debug("state exit: " .. display_text(old_name) .. frame_stamp())
                    end
                end
                -- Call the original exactly once with unchanged self/varargs.
                -- Its errors propagate (no pcall). Pack to preserve trailing nils.
                local results = _pack(orig_change(self, ...))
                -- Capture the incoming state AFTER the original has changed it.
                local new_state = self._state
                if new_state ~= nil and _type(self.current_state_name) == "function" and m then
                    local new_name = self:current_state_name()
                    local ok, err = _pcall(function()
                        m:on_game_state_changed("enter", new_name, new_state)
                    end)
                    if not ok then
                        log_contained_error("state enter drive failed: ", err)
                    else
                        log_debug("state enter: " .. display_text(new_name) .. frame_stamp())
                    end
                end
                return _unpack(results, 1, results.n)
            end
            bs.change_state_wrapped = true
            log_debug("bootstrap: GameStateMachine._change_state wrapped")
        else
            if not bs.change_state_missing_logged then
                log_debug("bootstrap: CLASS.GameStateMachine._change_state not yet available; will retry")
                bs.change_state_missing_logged = true
            end
        end
    end

    -- Step 4: wrap CLASS.GameStateMachine.destroy. Dispatches a final "exit" for
    --    the current state BEFORE the engine destroys it, unless already exited.
    --    Same style as Step 3: reads self._state + current_state_name() (never
    --    writes), dedup via _claim_exit, original runs once with unchanged args
    --    (errors propagate; trailing nils preserved). Mod-callback errors are
    --    pcall-contained.
    if not bs.destroy_wrapped then
        local gsm = CLASS and _rawget(CLASS, "GameStateMachine")
        if gsm and _type(gsm.destroy) == "function" then
            local orig_destroy = gsm.destroy
            gsm.destroy = function(self, ...)
                local m = Managers and Managers.mod
                -- Dispatch the final exit BEFORE the original destroys the state.
                -- Same gate as Step 3's exit. Name + object derived before the
                -- original so destroy's own mutation cannot change what is
                -- forwarded.
                local cur_state = self._state
                if cur_state ~= nil
                   and _type(self.current_state_name) == "function"
                   and m and _claim_exit(self, cur_state) then
                    local cur_name = self:current_state_name()
                    local ok, err = _pcall(function()
                        m:on_game_state_changed("exit", cur_name, cur_state)
                    end)
                    if not ok then
                        log_contained_error("final state exit drive failed: ", err)
                    else
                        log_debug("state exit (final): " .. display_text(cur_name) .. frame_stamp())
                    end
                end
                -- Original runs exactly once with unchanged self/varargs. Its
                -- errors propagate (no pcall). Pack to preserve trailing nils.
                local results = _pack(orig_destroy(self, ...))
                return _unpack(results, 1, results.n)
            end
            bs.destroy_wrapped = true
            log_debug("bootstrap: GameStateMachine.destroy wrapped")
        else
            if not bs.destroy_missing_logged then
                log_debug("bootstrap: CLASS.GameStateMachine.destroy not yet available; will retry")
                bs.destroy_missing_logged = true
            end
        end
    end

    -- Step 5 (opt-in --skip-splash): wrap CLASS.StateSplash.on_enter to skip the
    --    intro splash. Takes the engine's OWN skip branch: sets the same init
    --    fields + skip flags the engine sets on its internal _should_skip(), so
    --    the view is NEVER opened (no flash, no orphaned open/close) and update()
    --    advances to StateTitle on the first tick. The original on_enter is NOT
    --    called in the skip path (calling it would open the view); the engine's
    --    skip-branch init is replicated field-for-field. StateTitle is resolved
    --    via the engine's require; clean degradation at every layer: absent
    --    class/method → log-once + retry; StateTitle unresolved or skip-assignment
    --    error → log-once + pcall + vanilla on_enter.
    if _skip_splash_enabled and not bs.splash_wrapped then
        local splash = CLASS and _rawget(CLASS, "StateSplash")
        if splash and _type(splash.on_enter) == "function" then
            local orig_on_enter = splash.on_enter
            splash.on_enter = function(self, parent, params, creation_context)
                local StateTitle = _resolve_state_title()
                if StateTitle then
                    -- Skip-branch field assignments run under _pcall; on error
                    -- it falls back to the original (vanilla splash). They
                    -- replicate the engine's own skip path exactly.
                    local ok, err = _pcall(function()
                        self._creation_context = creation_context
                        self._next_state = StateTitle
                        self._next_state_params = params
                        params.skip_title_screen_on_invite = true
                        self._should_skip = true
                        self._continue = true
                    end)
                    if ok then
                        return
                    end
                    log_error("splash skip failed; falling back to vanilla: " .. _tostring(err))
                end
                -- StateTitle unresolved OR skip errored: vanilla splash.
                return orig_on_enter(self, parent, params, creation_context)
            end
            bs.splash_wrapped = true
            log_debug("bootstrap: StateSplash.on_enter wrapped")
        else
            if not bs.splash_missing_logged then
                log_debug("bootstrap: CLASS.StateSplash.on_enter not yet available; will retry")
                bs.splash_missing_logged = true
            end
        end
    end

    -- All steps complete -> short-circuit. The chassis-duties step must also
    --    be resolved (a manager whose establish/observer duties keep failing
    --    is a degraded install; keep retrying, never complete silently).
    --    Opted in, the splash step must be RESOLVED — wrapped or
    --    logged-missing (an absent optional StateSplash must not block
    --    completion forever, unlike a missing StateGame).
    if bs.manager_created and bs.chassis_duties_done
       and bs.state_game_wrapped
       and bs.change_state_wrapped and bs.destroy_wrapped
       and (not _skip_splash_enabled or bs.splash_wrapped or bs.splash_missing_logged) then
        bs.completed = true
    end
end

-- ---------------------------------------------------------------------------
-- Coordinator — called after every require by require_bridge.
-- ---------------------------------------------------------------------------
local function coordinate_bootstrap()
    -- 1. Install the class registry the moment `class` becomes a function.
    local install_class = Mods.install_class_registry
    if _type(install_class) == "function" then
        install_class()
    end

    -- 2. Wrap BootStateRequireGameScripts._state_update exactly once it exists.
    if not bs.boot_wrapped and CLASS then
        local bsr = _rawget(CLASS, "BootStateRequireGameScripts")
        if bsr and _type(bsr._state_update) == "function" then
            local orig_state_update = bsr._state_update
            -- Original runs first; return values preserved (packed with n so
            -- trailing nils survive), errors NOT swallowed. advance_bootstrap
            -- runs protected so a loader failure degrades to vanilla + a log
            -- line and retries on the next _state_update tick.
            bsr._state_update = function(self, ...)
                local results = _pack(orig_state_update(self, ...))
                local ok, err = _pcall(advance_bootstrap)
                if not ok then
                    log_contained_error("bootstrap failed: ", err)
                end
                return _unpack(results, 1, results.n)
            end
            bs.boot_wrapped = true
        end
    end

    -- 3. Wrap CLASS.StateBoot.update as the tick driver: it runs exactly once
    --    per engine update for the WHOLE boot phase (the boot sub-states,
    --    including BootStateRequireGameScripts, nest inside it), so tick
    --    observation starts at the first engine update after injection. The
    --    coordinator fires after every require during main.lua's initial
    --    loads (pre-first-update), so the wrap is in place before Main.update
    --    #1. The bump runs at wrap ENTRY — the Main.update boundary where the
    --    engine increments FRAME_INDEX; original results/errors pass through
    --    unchanged (errors propagate, return-cardinality preserved).
    if not bs.tick_boot_wrapped and CLASS then
        local sbt = _rawget(CLASS, "StateBoot")
        if sbt and _type(sbt.update) == "function" then
            local orig_boot_update = sbt.update
            sbt.update = function(self, ...)
                _tick_bump()
                local results = _pack(orig_boot_update(self, ...))
                return _unpack(results, 1, results.n)
            end
            bs.tick_boot_wrapped = true
            log_debug("bootstrap: StateBoot.update wrapped")
        end
    end
end

Mods.coordinate_bootstrap = coordinate_bootstrap
