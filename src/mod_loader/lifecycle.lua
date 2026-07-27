-- lifecycle.lua — the bootstrap coordinator + retryable boot wrapper.
--
-- No generic string-path hook API, no loadstring-driven hook chains. The
-- coordinator is invoked after every require (by require_bridge) and advances
-- two things, each idempotent:
--   1. ask class_registry to install once the engine's `class` appears;
--   2. once CLASS.BootStateRequireGameScripts._state_update is a function,
--      wrap that table field exactly once with a closure.
--
-- The boot wrapper calls the original _state_update first (preserving its
-- return values, including embedded/trailing nils, and NOT swallowing its
-- errors), then runs a protected advance_bootstrap that attempts only the
-- missing steps:
--   - loads the Relay mod_manager module from MOD_LOADER_DIR;
--   - instantiates Managers.mod once;
--   - directly wraps CLASS.StateGame.update exactly once so
--     Managers.mod:update(dt) runs BEFORE the engine update;
--   - directly wraps CLASS.GameStateMachine._change_state exactly once,
--     dispatching exit BEFORE and enter AFTER the engine transition;
--   - directly wraps CLASS.GameStateMachine.destroy exactly once, dispatching
--     a final exit for the current state BEFORE the engine destroys it;
--   - when the user opts in via --skip-splash / RELAY_SKIP_SPLASH=1, directly
--     wraps CLASS.StateSplash.on_enter exactly once so the intro splash state
--     is skipped (takes the engine's own skip branch cleanly — the view is
--     never opened — and degrades to vanilla splash if StateTitle is
--     unresolvable).
--
-- Retry semantics: every invocation of the already-installed _state_update
-- wrapper calls advance_bootstrap. Each step is independently idempotent, so a
-- partial first pass (e.g. StateGame not yet materialized) does not prevent a
-- later pass from finishing — the manager is created once, each field is
-- wrapped once, and once all steps complete a `completed` flag makes
-- later calls cheap.
--
-- GameStateMachine contract (engine-facing, not synthesized here): the engine
-- holds the current state as `self._state` and exposes a `current_state_name()`
-- method that derives its name. The _change_state wrapper only READS those — it
-- never writes a state field. Before the original, it reads the outgoing state;
-- after the original returns (having changed self._state), it reads the incoming
-- state. The destroy wrapper reads the same two surfaces before the original
-- destroy runs.
--
-- Exactly-once final exit: a state destroyed without a preceding _change_state
-- exit (the observed shutdown path) gets exactly one exit dispatch from the
-- destroy wrapper; a state already exited by _change_state is not redispatched.
-- The dedup is a private per-state-machine side-track of the last-exited state
-- object (identity-compared), shared between the two wrappers via _claim_exit.
-- No public manager fields; the engine's _state is never mutated.
--
-- Wrapping uses direct (owner_table, method_key) references — no dotted
-- strings, no global hook registries, no chains, no enable/disable, no dynamic
-- code generation. Missing class/method at bootstrap time produces a
-- controlled log + vanilla degradation, never a game crash.

local _pcall = pcall
local _tostring = tostring
local _unpack = unpack
local _select = select
local _rawget = rawget
local _type = type

-- Leveled diagnostics (the shared helper init.lua publishes on Mods._relay
-- before this module loads). Each emits "{LEVEL} [mod_loader] {message}".
local log_info  = Mods._relay.log_info
local log_debug = Mods._relay.log_debug
local log_warn  = Mods._relay.log_warn
local log_error = Mods._relay.log_error

-- Snapshot the optional StateSplash skip ONCE at module-eval time. init.lua
-- reads the trampoline-baked RELAY_SKIP_SPLASH global and stores the boolean
-- in Mods._relay.skip_splash before this module loads. Nil-safe (the table or
-- field may be absent when the opt-in is off / the loader ran in a reduced
-- sandbox). When true, advance_bootstrap gains a 5th idempotent step that
-- wraps CLASS.StateSplash.on_enter so the splash state is skipped.
local _skip_splash_enabled = Mods and Mods._relay and Mods._relay.skip_splash == true

-- Resolve StateTitle (StateSplash's _next_state) via the engine's require.
-- state_splash.lua requires it at module top, so it's cached in package.loaded
-- by the time StateSplash is entered. Resolved lazily on the first on_enter
-- call and cached for every subsequent call. Returns nil + logs once if
-- unavailable (engine contract shift → the wrap falls back to vanilla splash).
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

-- Pack varargs preserving the count (including embedded/trailing nils). LuaJIT
-- 2.1 / Lua 5.1 has no table.pack, so the count is stored alongside the values
-- and used as the upper bound when unpacking. Used by the two wrappers that do
-- work after the original returns (so they cannot tail-call).
local function _pack(...)
    return { n = _select("#", ...), ... }
end

-- Per-state-machine side-track of the last state object that received an exit
-- dispatch. Identity-compared to guarantee exactly-one exit per state object:
-- a state already exited by _change_state is not redispatched by destroy, and a
-- state exited by destroy is not redispatched by a _change_state the original
-- destroy drives internally. Weak-keyed so destroyed state machines don't pin
-- memory. Module-private; never exposed on the manager or the engine instance.
local _last_exited = setmetatable({}, { __mode = "k" })

-- Claims the exit of `state` on state machine `gsm`. Returns true and records
-- it as the last-exited state if it was not already the last-exited state for
-- this machine; returns false (a no-op) if it was. Called only when a manager
-- exists and the exit will actually be dispatched, so a nil-manager transition
-- (boot, no mods yet) does not suppress a later destroy-time dispatch.
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
    -- manager step (load + create are separately idempotent)
    manager_class = nil,
    manager_class_loaded = false,
    manager_created = false,
    manager_missing_logged = false,
    -- state-game step
    state_game_wrapped = false,
    state_game_missing_logged = false,
    -- change-state step
    change_state_wrapped = false,
    change_state_missing_logged = false,
    -- destroy step (final state-exit dispatch before destruction)
    destroy_wrapped = false,
    destroy_missing_logged = false,
    -- splash-skip step (opt-in; only attempted when _skip_splash_enabled)
    splash_wrapped = false,
    splash_missing_logged = false,
}

-- ---------------------------------------------------------------------------
-- advance_bootstrap — attempts only missing steps. Called (protected) after
-- every _state_update invocation. Each step is independently idempotent.
-- ---------------------------------------------------------------------------
local function advance_bootstrap()
    if bs.completed then
        return
    end

    -- Step 1a: load the mod_manager class from the loader root (idempotent).
    if not bs.manager_class_loaded then
        local ModManager = Mods.load_module("mod_manager")
        if ModManager then
            bs.manager_class = ModManager
            bs.manager_class_loaded = true
        else
            if not bs.manager_missing_logged then
                log_debug("bootstrap: mod_manager not yet loadable; will retry")
                bs.manager_missing_logged = true
            end
        end
    end

    -- Step 1b: instantiate Managers.mod exactly once (idempotent). Done as a
    --    separate step from the load so a load that succeeds but a :new() that
    --    raises can retry creation without re-loading.
    if bs.manager_class_loaded and not bs.manager_created then
        Managers = Managers or {}
        if not Managers.mod then
            Managers.mod = bs.manager_class:new()
        end
        bs.manager_created = true
    end

    -- Step 2: wrap CLASS.StateGame.update exactly once. Managers.mod:update(dt)
    --    runs BEFORE the engine update so mods see pre-frame state. The wrapper
    --    reads Managers.mod at call time, so installing it before the manager
    --    exists is harmless (the update loop no-ops until the manager appears).
    if not bs.state_game_wrapped then
        local sg = CLASS and _rawget(CLASS, "StateGame")
        if sg and _type(sg.update) == "function" then
            local orig_update = sg.update
            sg.update = function(self, dt, ...)
                local m = Managers and Managers.mod
                if m then
                    local ok, err = _pcall(function()
                        m:update(dt)
                    end)
                    if not ok then
                        log_error("Managers.mod:update failed: " .. _tostring(err))
                    end
                end
                return orig_update(self, dt, ...)
            end
            bs.state_game_wrapped = true
        else
            if not bs.state_game_missing_logged then
                log_debug("bootstrap: CLASS.StateGame.update not yet available; will retry")
                bs.state_game_missing_logged = true
            end
        end
    end

    -- Step 3: wrap CLASS.GameStateMachine._change_state exactly once. Dispatch
    --    "exit" before the transition and "enter" after it. The outgoing/
    --    incoming states are READ from the engine-maintained self._state
    --    (captured before and after the original), and their names derived via
    --    the engine's current_state_name() method. This wrapper never writes a
    --    state field. Exit is deduplicated against the destroy wrapper via
    --    _claim_exit so a state exited here is not redispatched on destruction.
    if not bs.change_state_wrapped then
        local gsm = CLASS and _rawget(CLASS, "GameStateMachine")
        if gsm and _type(gsm._change_state) == "function" then
            local orig_change = gsm._change_state
            gsm._change_state = function(self, ...)
                local m = Managers and Managers.mod
                -- Capture the outgoing state BEFORE the original runs. Dispatch
                -- exit only when there is a current state, the engine exposes
                -- current_state_name() to derive its name, a manager exists, and
                -- the state has not already been exited (dedup shared with the
                -- destroy wrapper).
                local old_state = self._state
                if old_state ~= nil
                   and _type(self.current_state_name) == "function"
                   and m and _claim_exit(self, old_state) then
                    local old_name = self:current_state_name()
                    local ok, err = _pcall(function()
                        m:on_game_state_changed("exit", old_name, old_state)
                    end)
                    if not ok then
                        log_error("state exit drive failed: " .. _tostring(err))
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
                        log_error("state enter drive failed: " .. _tostring(err))
                    end
                end
                return _unpack(results, 1, results.n)
            end
            bs.change_state_wrapped = true
        else
            if not bs.change_state_missing_logged then
                log_debug("bootstrap: CLASS.GameStateMachine._change_state not yet available; will retry")
                bs.change_state_missing_logged = true
            end
        end
    end

    -- Step 4: wrap CLASS.GameStateMachine.destroy exactly once. Dispatches a
    --    final "exit" for the current state BEFORE the engine destroys it,
    --    unless that state was already exited (by _change_state or a prior
    --    destroy-side dispatch). Mirrors Step 3's wrap style: reads
    --    self._state + current_state_name() (never writes), dedup via the shared
    --    _claim_exit, original runs exactly once with unchanged args, its return
    --    values (incl. trailing nils) are preserved via _pack/_unpack, and its
    --    errors propagate (no pcall around the original). Mod-callback errors
    --    are pcall-contained.
    if not bs.destroy_wrapped then
        local gsm = CLASS and _rawget(CLASS, "GameStateMachine")
        if gsm and _type(gsm.destroy) == "function" then
            local orig_destroy = gsm.destroy
            gsm.destroy = function(self, ...)
                local m = Managers and Managers.mod
                -- Dispatch the final exit BEFORE the original destroys the
                -- state. Same gate as Step 3's exit: current state present,
                -- current_state_name() available, manager exists, not already
                -- exited. The name + object are derived before the original so
                -- destroy's own mutation cannot change what is forwarded.
                local cur_state = self._state
                if cur_state ~= nil
                   and _type(self.current_state_name) == "function"
                   and m and _claim_exit(self, cur_state) then
                    local cur_name = self:current_state_name()
                    local ok, err = _pcall(function()
                        m:on_game_state_changed("exit", cur_name, cur_state)
                    end)
                    if not ok then
                        log_error("final state exit drive failed: " .. _tostring(err))
                    end
                end
                -- Original runs exactly once with unchanged self/varargs. Its
                -- errors propagate (no pcall). Pack to preserve trailing nils.
                local results = _pack(orig_destroy(self, ...))
                return _unpack(results, 1, results.n)
            end
            bs.destroy_wrapped = true
        else
            if not bs.destroy_missing_logged then
                log_debug("bootstrap: CLASS.GameStateMachine.destroy not yet available; will retry")
                bs.destroy_missing_logged = true
            end
        end
    end

    -- Step 5 (opt-in): wrap CLASS.StateSplash.on_enter exactly once so the
    --    engine's intro splash state is skipped when the user opts in via
    --    --skip-splash / RELAY_SKIP_SPLASH=1. The wrap takes the engine's OWN
    --    skip branch cleanly: it sets the same init fields + skip flags the
    --    engine sets when its internal _should_skip() predicate returns true,
    --    so the view is NEVER opened (no flash, no orphaned open/close) and
    --    update() advances to StateTitle on the first tick. The original
    --    on_enter is NOT called in the skip path (calling it would open the
    --    view, defeating the skip); instead the engine's skip-branch init is
    --    replicated field-for-field. StateTitle is resolved via the engine's
    --    require (state_splash.lua requires it at module top, so it's cached);
    --    if unavailable (engine contract shift) the wrap falls back to the
    --    original on_enter (vanilla splash). Clean degradation at every layer:
    --    absent class/method → log-once + retry; StateTitle unresolved →
    --    log-once + vanilla on_enter; skip-assignment error → pcall + vanilla.
    if _skip_splash_enabled and not bs.splash_wrapped then
        local splash = CLASS and _rawget(CLASS, "StateSplash")
        if splash and _type(splash.on_enter) == "function" then
            local orig_on_enter = splash.on_enter
            splash.on_enter = function(self, parent, params, creation_context)
                local StateTitle = _resolve_state_title()
                if StateTitle then
                    -- Relay's own work (the skip-branch field assignments) runs
                    -- under _pcall; on any error it falls back to the original
                    -- (vanilla splash). The assignments replicate the engine's
                    -- own skip path exactly.
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
        else
            if not bs.splash_missing_logged then
                log_debug("bootstrap: CLASS.StateSplash.on_enter not yet available; will retry")
                bs.splash_missing_logged = true
            end
        end
    end

    -- All steps complete -> cheap short-circuit on later calls. The splash step
    -- is gated on the opt-in: when opted OUT it is never attempted and must not
    -- block completion (the disjunction short-circuits to true). When opted IN,
    -- completion requires the splash step to have RESOLVED — either wrapped
    -- (success) or logged-missing (clean degradation if the engine contract
    -- shifted and StateSplash is absent). Without the missing-logged term, an
    -- absent StateSplash would block completion forever, re-checking on every
    -- _state_update tick (StateSplash is OPTIONAL — its absence is benign, not
    -- a bootstrap failure like missing StateGame would be).
    if bs.manager_created and bs.state_game_wrapped
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
            -- Original runs first and its return values are preserved (packed
            -- with n so embedded/trailing nils survive). Its errors are NOT
            -- swallowed (no pcall around the original). advance_bootstrap runs
            -- in a protected call so a loader failure degrades to vanilla +
            -- a log line, and is retried on the next _state_update tick.
            bsr._state_update = function(self, ...)
                local results = _pack(orig_state_update(self, ...))
                local ok, err = _pcall(advance_bootstrap)
                if not ok then
                    log_error("bootstrap failed: " .. _tostring(err))
                end
                return _unpack(results, 1, results.n)
            end
            bs.boot_wrapped = true
        end
    end
end

Mods.coordinate_bootstrap = coordinate_bootstrap
