-- lifecycle.lua — the bootstrap coordinator + retryable boot wrapper.
--
-- The coordinator runs after every require (via require_bridge) and advances,
-- each idempotent: (1) install class_registry once `class` is a function;
-- (2) once CLASS.BootStateRequireGameScripts._state_update is a function, wrap
-- it exactly once with a closure.
--
-- The boot wrapper calls the original _state_update first (preserving return
-- values incl. trailing nils; NOT swallowing its errors), then runs a protected
-- advance_bootstrap that attempts only the missing steps:
--   - load the Relay mod_manager + instantiate Managers.mod once;
--   - wrap CLASS.StateGame.update so Managers.mod:update(dt) runs BEFORE the
--     engine update;
--   - wrap CLASS.GameStateMachine._change_state, dispatching "exit" BEFORE and
--     "enter" AFTER the engine transition;
--   - wrap CLASS.GameStateMachine.destroy, dispatching a final "exit" for the
--     current state BEFORE the engine destroys it;
--   - (opt-in --skip-splash) wrap CLASS.StateSplash.on_enter to skip the splash
--     (takes the engine's own skip branch; degrades to vanilla if StateTitle is
--     unresolvable).
--
-- Each step is independently idempotent; a partial pass retries on the next
-- _state_update tick until a `completed` flag short-circuits.
--
-- GameStateMachine contract: the engine holds self._state + current_state_name();
-- the wrappers only READ those — never write a state field. A state destroyed
-- without a preceding _change_state exit gets exactly one exit dispatch from
-- the destroy wrapper; one already exited is not redispatched. Dedup is a
-- private per-state-machine side-track (identity-compared), shared between the
-- two wrappers via _claim_exit. Missing class/method at bootstrap → log-once +
-- vanilla degradation, never a game crash.

local _pcall = pcall
local _tostring = tostring
local _unpack = unpack
local _select = select
local _rawget = rawget
local _type = type

-- Leveled diagnostics (init.lua publishes the helper on Mods._relay before this
-- module loads).
local log_info  = Mods._relay.log_info
local log_debug = Mods._relay.log_debug
local log_warn  = Mods._relay.log_warn
local log_error = Mods._relay.log_error

-- Snapshot the StateSplash skip ONCE at module-eval time (init.lua stored it in
-- Mods._relay.skip_splash). Nil-safe. When true, advance_bootstrap gains a 5th
-- idempotent step that wraps CLASS.StateSplash.on_enter.
local _skip_splash_enabled = Mods and Mods._relay and Mods._relay.skip_splash == true

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
-- advance_bootstrap — attempts only missing steps (each independently
-- idempotent). Called protected after every _state_update.
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

    -- Step 1b: instantiate Managers.mod exactly once. Separate from the load so
    --    a load that succeeds but a :new() that raises can retry creation
    --    without re-loading.
    if bs.manager_class_loaded and not bs.manager_created then
        Managers = Managers or {}
        if not Managers.mod then
            Managers.mod = bs.manager_class:new()
        end
        bs.manager_created = true
    end

    -- Step 2: wrap CLASS.StateGame.update so Managers.mod:update(dt) runs BEFORE
    --    the engine update (mods see pre-frame state). Reads Managers.mod at
    --    call time, so installing before the manager exists is harmless.
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
        else
            if not bs.splash_missing_logged then
                log_debug("bootstrap: CLASS.StateSplash.on_enter not yet available; will retry")
                bs.splash_missing_logged = true
            end
        end
    end

    -- All steps complete -> short-circuit. The splash step is gated on the
    -- opt-in: opted OUT, it is never attempted and must not block completion.
    -- Opted IN, completion needs the splash step RESOLVED — wrapped or
    -- logged-missing. The missing-logged term is load-bearing: without it, an
    -- absent (optional) StateSplash would block completion forever, re-checking
    -- every tick (StateSplash's absence is benign, unlike a missing StateGame).
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
            -- Original runs first; return values preserved (packed with n so
            -- trailing nils survive), errors NOT swallowed. advance_bootstrap
            -- runs protected so a loader failure degrades to vanilla + a log
            -- line and retries on the next _state_update tick.
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
