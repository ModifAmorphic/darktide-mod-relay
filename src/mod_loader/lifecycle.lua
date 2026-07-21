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
--     dispatching exit BEFORE and enter AFTER the engine transition.
--
-- Retry semantics: every invocation of the already-installed _state_update
-- wrapper calls advance_bootstrap. Each step is independently idempotent, so a
-- partial first pass (e.g. StateGame not yet materialized) does not prevent a
-- later pass from finishing — the manager is created once, each field is
-- wrapped once, and once all three steps complete a `completed` flag makes
-- later calls cheap.
--
-- GameStateMachine contract (engine-facing, not synthesized here): the engine
-- holds the current state as `self._state` and exposes a `current_state_name()`
-- method that derives its name. This wrapper only READS those — it never writes
-- a state field. Before the original, it reads the outgoing state; after the
-- original returns (having changed self._state), it reads the incoming state.
--
-- Wrapping uses direct (owner_table, method_key) references — no dotted
-- strings, no global hook registries, no chains, no enable/disable, no dynamic
-- code generation. Missing class/method at bootstrap time produces a
-- controlled log + vanilla degradation, never a game crash.

local _pcall = pcall
local _print = __print or print
local _tostring = tostring
local _unpack = unpack
local _select = select
local _rawget = rawget
local _type = type

-- Pack varargs preserving the count (including embedded/trailing nils). LuaJIT
-- 2.1 / Lua 5.1 has no table.pack, so the count is stored alongside the values
-- and used as the upper bound when unpacking. Used by the two wrappers that do
-- work after the original returns (so they cannot tail-call).
local function _pack(...)
    return { n = _select("#", ...), ... }
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
                _print("[mod_loader] bootstrap: mod_manager not yet loadable; will retry")
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
                        _print("[mod_loader] Managers.mod:update failed: " .. _tostring(err))
                    end
                end
                return orig_update(self, dt, ...)
            end
            bs.state_game_wrapped = true
        else
            if not bs.state_game_missing_logged then
                _print("[mod_loader] bootstrap: CLASS.StateGame.update not yet available; will retry")
                bs.state_game_missing_logged = true
            end
        end
    end

    -- Step 3: wrap CLASS.GameStateMachine._change_state exactly once. Dispatch
    --    "exit" before the transition and "enter" after it. The outgoing/
    --    incoming states are READ from the engine-maintained self._state
    --    (captured before and after the original), and their names derived via
    --    the engine's current_state_name() method. This wrapper never writes a
    --    state field.
    if not bs.change_state_wrapped then
        local gsm = CLASS and _rawget(CLASS, "GameStateMachine")
        if gsm and _type(gsm._change_state) == "function" then
            local orig_change = gsm._change_state
            gsm._change_state = function(self, ...)
                local m = Managers and Managers.mod
                -- Capture the outgoing state BEFORE the original runs. Only
                -- dispatch exit when there is a current state AND the engine
                -- exposes current_state_name() to derive its name.
                local old_state = self._state
                if old_state ~= nil and _type(self.current_state_name) == "function" then
                    local old_name = self:current_state_name()
                    if m then
                        local ok, err = _pcall(function()
                            m:on_game_state_changed("exit", old_name, old_state)
                        end)
                        if not ok then
                            _print("[mod_loader] state exit drive failed: " .. _tostring(err))
                        end
                    end
                end
                -- Call the original exactly once with unchanged self/varargs.
                -- Its errors propagate (no pcall). Pack to preserve trailing nils.
                local results = _pack(orig_change(self, ...))
                -- Capture the incoming state AFTER the original has changed it.
                local new_state = self._state
                if new_state ~= nil and _type(self.current_state_name) == "function" then
                    local new_name = self:current_state_name()
                    if m then
                        local ok, err = _pcall(function()
                            m:on_game_state_changed("enter", new_name, new_state)
                        end)
                        if not ok then
                            _print("[mod_loader] state enter drive failed: " .. _tostring(err))
                        end
                    end
                end
                return _unpack(results, 1, results.n)
            end
            bs.change_state_wrapped = true
        else
            if not bs.change_state_missing_logged then
                _print("[mod_loader] bootstrap: CLASS.GameStateMachine._change_state not yet available; will retry")
                bs.change_state_missing_logged = true
            end
        end
    end

    -- All steps complete -> cheap short-circuit on later calls.
    if bs.manager_created and bs.state_game_wrapped and bs.change_state_wrapped then
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
                    _print("[mod_loader] bootstrap failed: " .. _tostring(err))
                end
                return _unpack(results, 1, results.n)
            end
            bs.boot_wrapped = true
        end
    end
end

Mods.coordinate_bootstrap = coordinate_bootstrap
