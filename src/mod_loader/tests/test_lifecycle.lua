-- test_lifecycle.lua — bootstrap coordinator + boot/state wrapping (src/mod_loader/lifecycle.lua).
--
-- Asserts observable behavior:
--   - coordinator installs class_registry once `class` appears
--   - BootStateRequireGameScripts._state_update wrapped exactly once
--   - original _state_update runs FIRST (its return preserved); bootstrap runs after
--   - bootstrap loads mod_manager + instantiates Managers.mod once, then runs the
--     manager-agnostic chassis duties (Step 1c: single dmf_adapter module load +
--     establish + exactly-one io observer + Crashify version publication)
--   - StateGame.update wrapped once; Managers.mod:update runs BEFORE engine update
--   - GameStateMachine._change_state wrapped once; exit BEFORE + enter AFTER the transition
--   - missing class/method degrades to a log + vanilla (no crash)
--   - original engine errors are not swallowed

local mock = require("mock")

return function(runner)
    -- Load class_registry + lifecycle into a sandbox. Returns the sandbox +
    -- helper to drive the class-appear -> BSR wrap sequence. print_fn lets a
    -- test inject a logging spy BEFORE the modules capture __print at load.
    local function setup(print_fn)
        local sb = mock.new_sandbox()
        sb.Mods = {}
        -- lifecycle reads leveled diagnostics from Mods._relay.log_<level> (the
        -- helper init.lua publishes in production). Isolated test — attach it.
        mock.attach_logger(sb)
        -- A valid version + silent Crashify stub so the chassis Step-1c version
        -- publication succeeds quietly (tests asserting log positions depend on
        -- the extra diagnostics NOT appearing; version-publication behavior is
        -- covered by the dedicated chassis tests below).
        sb.Mods._relay.version = "0.3.0-beta.2"
        sb.Crashify = { print_property = function() end }
        sb.Managers = {}
        sb.__print = print_fn or function() end

        -- fake engine class(): returns a fresh table per name; wrapper stores
        -- it in CLASS[name]. Tests populate the returned tables with methods.
        sb.class = function(name, ...)
            return { name = name }
        end

        -- fake ModManager (loaded by the bootstrap via Mods.load_module).
        -- new() yields an instance whose update/on_game_state_changed are
        -- spies the test can observe. dmf_adapter is served REAL: lifecycle's
        -- module scope loads it exactly once (the chassis publish Step 1c and
        -- mod_manager's init read), and its establish/register are
        -- manager-agnostic.
        local manager_updates = {}
        local manager_gsc = {}
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                return {
                    new = function()
                        return {
                            update = function(self, dt)
                                table.insert(manager_updates, dt)
                            end,
                            on_game_state_changed = function(self, status, sname, sobj)
                                table.insert(manager_gsc, { status, sname })
                            end,
                        }
                    end,
                }
            end
        end

        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        return sb, manager_updates, manager_gsc
    end

    -- Drive the coordinator through the "class appears -> wrapper installs"
    -- step, then declare the BootStateRequireGameScripts class with a method,
    -- then drive the coordinator again so it wraps _state_update.
    local function setup_boot_wrapped(orig_state_update)
        local sb, mu, mg = setup()
        sb.Mods.coordinate_bootstrap()  -- installs class wrapper
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = orig_state_update or function() end
        sb.Mods.coordinate_bootstrap()  -- wraps _state_update
        return sb, bsr, mu, mg
    end

    -- ---------------------------------------------------------------------
    -- Coordinator + class install
    -- ---------------------------------------------------------------------

    runner.register("lifecycle: coordinator installs the class registry", function()
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        -- After coordinate, class is wrapped (install_class_registry ran).
        -- Verify by calling class() and checking CLASS is populated.
        local foo = sb.class("Foo")
        runner.assert_eq(foo, sb.CLASS.Foo, "coordinate_bootstrap must install class registry")
    end)

    runner.register("lifecycle: coordinator is safe to call repeatedly (idempotent)", function()
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        sb.Mods.coordinate_bootstrap()
        sb.Mods.coordinate_bootstrap()
        runner.assert_type("function", sb.Mods.coordinate_bootstrap)
    end)

    -- ---------------------------------------------------------------------
    -- Boot wrap exact-once + original-first
    -- ---------------------------------------------------------------------

    runner.register("lifecycle: BootStateRequireGameScripts._state_update wrapped exactly once", function()
        local calls = 0
        local sb, bsr = setup_boot_wrapped(function() calls = calls + 1 end)
        bsr._state_update(bsr)
        runner.assert_eq(1, calls, "original _state_update called once")
        -- A second coordinator call must not re-wrap (boot_wrapped flag).
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)
        runner.assert_eq(2, calls, "second wrap attempt did not double-call")
    end)

    runner.register("lifecycle: original _state_update runs BEFORE the bootstrap section", function()
        -- Track the order: original update -> mod_manager load -> Managers.mod.
        local seq = {}
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function()
            table.insert(seq, "original_state_update")
        end
        -- ModManager load + Managers.mod assignment happen in the bootstrap,
        -- which runs AFTER the original. Observe via load_module spy.
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                table.insert(seq, "load_module(mod_manager)")
                return { new = function()
                    table.insert(seq, "ModManager:new")
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()  -- wraps _state_update
        bsr._state_update(bsr)  -- triggers original then bootstrap
        runner.assert_eq("original_state_update", seq[1],
            "original _state_update must run first")
        runner.assert_eq("load_module(mod_manager)", seq[2],
            "bootstrap runs after the original")
    end)

    runner.register("lifecycle: original _state_update return value preserved", function()
        local sb, bsr = setup_boot_wrapped(function() return "engine-result", 7 end)
        local r1, r2 = bsr._state_update(bsr)
        runner.assert_eq("engine-result", r1, "first return preserved")
        runner.assert_eq(7, r2, "second return preserved")
    end)

    runner.register("lifecycle: _state_update preserves return values with embedded/trailing nils", function()
        -- Regression: { orig(...) } + unpack(results) loses trailing nils and
        -- truncates at the first embedded nil. The pack helper (n=select('#'))
        -- must preserve all 4 slots: "a", nil, "b", nil.
        local sb, bsr = setup_boot_wrapped(function() return "a", nil, "b", nil end)
        local r1, r2, r3, r4, r5 = bsr._state_update(bsr)
        runner.assert_eq("a", r1)
        runner.assert_nil(r2, "embedded nil at slot 2 must be preserved")
        runner.assert_eq("b", r3)
        runner.assert_nil(r4, "trailing nil at slot 4 must be preserved")
        runner.assert_nil(r5, "nothing beyond slot 4")
        -- And the count is exactly 4 (the trailing nil didn't truncate the list).
        runner.assert_eq(4, select("#", bsr._state_update(bsr)),
            "select('#', ...) must report 4 returns, not truncate at the nils")
    end)

    runner.register("lifecycle: Managers.mod instantiated once (idempotent across boots)", function()
        local news = 0
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    news = news + 1
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)
        bsr._state_update(bsr)  -- second boot tick
        runner.assert_eq(1, news, "ModManager instantiated exactly once")
        runner.assert_not_nil(sb.Managers.mod, "Managers.mod set")
    end)

    -- ---------------------------------------------------------------------
    -- StateGame.update order (Managers.mod:update BEFORE engine update)
    -- ---------------------------------------------------------------------

    runner.register("lifecycle: StateGame.update wrapped; Managers.mod:update runs BEFORE engine update", function()
        local seq = {}
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function(self, dt) table.insert(seq, "mod:update(" .. dt .. ")") end,
                        on_game_state_changed = function() end,
                    }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        -- StateGame must exist BEFORE _state_update fires (the original
        -- _state_update requires game scripts including StateGame).
        local sg = sb.class("StateGame")
        sg.update = function(self, dt) table.insert(seq, "engine:update(" .. dt .. ")") end
        bsr._state_update(bsr)  -- bootstrap wraps StateGame.update
        -- Now drive a StateGame instance: the wrapped class method runs.
        sg.update(sg, 0.016)
        runner.assert_eq({ "mod:update(0.016)", "engine:update(0.016)" }, seq,
            "Managers.mod:update must run BEFORE the engine update")
    end)

    runner.register("lifecycle: StateGame.update wrapped exactly once across multiple boots", function()
        local e_calls = 0
        local m_calls = 0
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function() m_calls = m_calls + 1 end,
                        on_game_state_changed = function() end,
                    }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        local sg = sb.class("StateGame")
        sg.update = function() e_calls = e_calls + 1 end
        bsr._state_update(bsr)  -- first boot: wraps StateGame.update
        bsr._state_update(bsr)  -- second boot: must not re-wrap
        sg.update(sg, 1)
        runner.assert_eq(1, e_calls, "engine update called once per drive")
        runner.assert_eq(1, m_calls, "mod update called once per drive (no double-wrap)")
    end)

    -- ---------------------------------------------------------------------
    -- GameStateMachine._change_state exit/enter order
    --
    -- Engine-facing contract (modeled here, not synthesized by the wrapper):
    -- the engine holds the current state as `self._state` and exposes a
    -- `current_state_name()` method that derives its name. The original
    -- `_change_state` transitions `self._state` to the new state object. The
    -- wrapper READS self._state + current_state_name() before (exit) and after
    -- (enter) the original — it never writes a state field.
    -- ---------------------------------------------------------------------

    -- Build a GameStateMachine whose _change_state changes self._state (the
    -- engine behavior), and current_state_name derives the name from it. The
    -- outgoing state object is captured by the wrapper for the exit dispatch.
    -- Models destroy as a no-op so the full bootstrap (incl. the destroy wrap)
    -- can complete; tests needing a custom destroy body build their own GSM.
    local function setup_gsm(sb, seq, on_gsc)
        local gsm = sb.class("GameStateMachine")
        -- Engine _change_state(self, new_state_name): assigns the new state.
        gsm._change_state = function(self, new_name, ...)
            self._state = { name = new_name }
            if seq then table.insert(seq, "engine:_change_state") end
        end
        -- Engine current_state_name derives the name from self._state.
        gsm.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        gsm.destroy = function(self, ...)
            if seq then table.insert(seq, "engine:destroy") end
        end
        return gsm
    end

    -- Full-bootstrap helper for destroy-wrapper tests. Sets up the coordinator
    -- + BSR wrap + manager + StateGame + a GSM with _change_state,
    -- current_state_name, and destroy. The manager's on_game_state_changed is
    -- routed to opts.on_gsc (status, name, obj). opts.destroy_fn customizes the
    -- GSM destroy body. opts.print_fn captures diagnostics. Returns sb, gsm, bsr.
    local function setup_destroy(opts)
        opts = opts or {}
        local sb = mock.new_sandbox()
        sb.Mods = {}
        mock.attach_logger(sb)
        sb.Mods._relay.version = "0.3.0-beta.2"
        sb.Crashify = { print_property = function() end }
        sb.Managers = {}
        sb.__print = opts.print_fn or function() end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                return {
                    new = function()
                        return {
                            update = function() end,
                            on_game_state_changed = function(self, status, sname, sobj)
                                if opts.on_gsc then opts.on_gsc(status, sname, sobj) end
                            end,
                        }
                    end,
                }
            end
        end
        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.class("StateGame").update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, new_name) self._state = { name = new_name } end
        gsm.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        gsm.destroy = opts.destroy_fn or function(self, ...) end
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)  -- advance_bootstrap wraps StateGame + GSM
        return sb, gsm, bsr
    end

    runner.register("lifecycle: _change_state dispatches exit BEFORE + enter AFTER the transition", function()
        local seq = {}
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function() end,
                        on_game_state_changed = function(self, status, sname, sobj)
                            table.insert(seq, "mod:gsc:" .. status .. ":" .. tostring(sname))
                        end,
                    }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        local gsm = setup_gsm(sb, seq)
        bsr._state_update(bsr)  -- bootstrap wraps _change_state
        -- Instance with an existing current state (engine set it earlier).
        local inst = setmetatable({ _state = { name = "StateMainMenu" } }, { __index = gsm })
        inst:_change_state("StateIngame")
        runner.assert_eq({
            "mod:gsc:exit:StateMainMenu",
            "engine:_change_state",
            "mod:gsc:enter:StateIngame",
        }, seq, "exit must fire before, enter after the engine transition")
    end)

    runner.register("lifecycle: _change_state forwards the original state object in exit/enter", function()
        -- The exit dispatch carries the OLD state object; enter carries the NEW
        -- one (both read from self._state, not synthesized).
        local exits, enters = {}, {}
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        local old_obj = { name = "OldState", marker = "old" }
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function() end,
                        on_game_state_changed = function(self, status, sname, sobj)
                            if status == "exit" then exits.obj = sobj; exits.name = sname
                            elseif status == "enter" then enters.obj = sobj; enters.name = sname end
                        end,
                    }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        local gsm = setup_gsm(sb)
        bsr._state_update(bsr)
        local inst = setmetatable({ _state = old_obj }, { __index = gsm })
        inst:_change_state("NewState")
        runner.assert_eq(old_obj, exits.obj, "exit must carry the old self._state object")
        runner.assert_eq("OldState", exits.name)
        runner.assert_eq(inst._state, enters.obj, "enter must carry the new self._state object")
        runner.assert_eq("NewState", enters.name)
    end)

    runner.register("lifecycle: _change_state exit skipped on first transition (no current state)", function()
        -- If self._state is nil before the original (first transition), there
        -- is no outgoing state, so exit is skipped. enter still fires because
        -- the original sets self._state.
        local seq = {}
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function() end,
                        on_game_state_changed = function(self, status, sname)
                            table.insert(seq, status .. ":" .. tostring(sname))
                        end,
                    }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        local gsm = setup_gsm(sb, seq)
        bsr._state_update(bsr)
        local inst = setmetatable({}, { __index = gsm })  -- no _state yet
        inst:_change_state("StateFirst")
        runner.assert_eq({ "engine:_change_state", "enter:StateFirst" }, seq,
            "exit skipped when no current state; enter still fires")
    end)

    runner.register("lifecycle: _change_state dispatch skipped when current_state_name is absent", function()
        -- Graceful degradation: if the engine build doesn't expose
        -- current_state_name(), neither exit nor enter dispatches, and the
        -- original still runs unchanged.
        local gsc_called = false
        local engine_ran = false
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function() end,
                        on_game_state_changed = function() gsc_called = true end,
                    }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, ...) self._state = { name = "X" }; engine_ran = true end
        -- NOTE: no current_state_name defined on this GameStateMachine.
        bsr._state_update(bsr)
        local inst = setmetatable({ _state = { name = "Old" } }, { __index = gsm })
        inst:_change_state("X")
        runner.assert_eq(true, engine_ran, "original _change_state must still run")
        runner.assert_eq(false, gsc_called,
            "no on_game_state_changed when current_state_name is absent")
    end)

    runner.register("lifecycle: _change_state preserves return values with embedded/trailing nils", function()
        -- Regression: the _change_state wrapper packs the original's returns
        -- (n=select('#')) so embedded/trailing nils survive, then unpacks with
        -- the stored count.
        local seq = {}
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function() end,
                        on_game_state_changed = function(self, status, sname)
                            table.insert(seq, status .. ":" .. tostring(sname))
                        end,
                    }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        local gsm = sb.class("GameStateMachine")
        -- Original returns 4 values with embedded + trailing nils.
        gsm._change_state = function(self, ...)
            self._state = { name = "Next" }
            return "p", nil, "q", nil
        end
        gsm.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        bsr._state_update(bsr)
        local inst = setmetatable({ _state = { name = "Prev" } }, { __index = gsm })
        local r1, r2, r3, r4, r5 = inst:_change_state("Next")
        runner.assert_eq("p", r1)
        runner.assert_nil(r2, "embedded nil at slot 2 preserved")
        runner.assert_eq("q", r3)
        runner.assert_nil(r4, "trailing nil at slot 4 preserved")
        runner.assert_nil(r5, "nothing beyond slot 4")
        runner.assert_eq(4, select("#", inst:_change_state("Next")),
            "select('#') must report 4 returns despite the nils")
    end)

    runner.register("lifecycle: _change_state original error propagates (not swallowed)", function()
        -- The original _change_state's errors must propagate (no pcall around
        -- it), even though mod callback errors are isolated.
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function() error("engine transition boom") end
        gsm.current_state_name = function() return "X" end
        bsr._state_update(bsr)
        local inst = setmetatable({ _state = { name = "A" } }, { __index = gsm })
        local ok, err = pcall(function() inst:_change_state("B") end)
        runner.assert_eq(false, ok, "original _change_state error must propagate")
        runner.assert_truthy(tostring(err):find("engine transition boom") ~= nil)
    end)

    -- ---------------------------------------------------------------------
    -- Retryable bootstrap (partial first pass completes on a later tick)
    -- ---------------------------------------------------------------------

    runner.register("lifecycle: partial bootstrap — StateGame absent tick 1, completes tick 2", function()
        -- Tick 1: manager loads + GameStateMachine wraps, but StateGame is not
        -- yet materialized. Tick 2: StateGame appears and wraps. Manager stays
        -- a single instance; each field wraps exactly once.
        local news = 0
        local sg_update_calls = 0
        local gsm_change_calls = 0
        local sb = setup()
        sb.Mods.coordinate_bootstrap()  -- installs class wrapper
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    news = news + 1
                    return {
                        update = function() end,
                        on_game_state_changed = function() end,
                    }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()  -- wraps _state_update
        -- GameStateMachine present on tick 1; StateGame NOT yet declared.
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, ...) gsm_change_calls = gsm_change_calls + 1 end
        gsm.current_state_name = function() return "X" end
        gsm.destroy = function() end
        -- Tick 1: manager created + GSM wrapped, StateGame missing.
        bsr._state_update(bsr)
        runner.assert_eq(1, news, "manager created once on tick 1")
        runner.assert_eq(0, sg_update_calls, "StateGame not wrapped yet")
        -- StateGame materializes between ticks.
        local sg = sb.class("StateGame")
        sg.update = function(self, dt) sg_update_calls = sg_update_calls + 1 end
        -- Tick 2: StateGame now wraps; manager NOT re-created; GSM NOT re-wrapped.
        bsr._state_update(bsr)
        runner.assert_eq(1, news, "manager still exactly one instance after tick 2")
        -- Drive the wrapped methods to confirm they're attached + fire once.
        sg.update(sg, 0.016)
        local inst = setmetatable({ _state = { name = "A" } }, { __index = gsm })
        inst:_change_state("B")
        runner.assert_eq(1, sg_update_calls, "StateGame.update wrapped exactly once (tick 2)")
        runner.assert_eq(1, gsm_change_calls, "GameStateMachine._change_state wrapped once (tick 1, not re-wrapped)")
    end)

    runner.register("lifecycle: partial bootstrap — both classes absent tick 1, complete tick 2", function()
        local news = 0
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            return { new = function()
                news = news + 1
                return { update = function() end, on_game_state_changed = function() end }
            end }
        end
        sb.Mods.coordinate_bootstrap()
        -- Tick 1: neither StateGame nor GameStateMachine declared.
        bsr._state_update(bsr)
        runner.assert_eq(1, news, "manager created on tick 1 even though classes absent")
        -- Both classes materialize between ticks.
        local sg = sb.class("StateGame")
        sg.update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function() end
        gsm.current_state_name = function() return "X" end
        gsm.destroy = function() end
        -- Tick 2: both wrap; manager not re-created.
        bsr._state_update(bsr)
        runner.assert_eq(1, news, "manager still one instance")
        -- Tick 3: completed short-circuit — no re-wrap, no extra work.
        bsr._state_update(bsr)
        runner.assert_eq(1, news, "completed flag prevents re-creation on tick 3")
    end)

    runner.register("lifecycle: module load failure retries — succeeds on a later tick", function()
        -- load_module returns nil on tick 1 (transient failure); succeeds on
        -- tick 2. Manager is created exactly once (on the successful tick);
        -- StateGame/GSM wrap on tick 2 as well.
        local news = 0
        local load_attempts = 0
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                load_attempts = load_attempts + 1
                if load_attempts == 1 then
                    return nil  -- transient failure
                end
                return { new = function()
                    news = news + 1
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        local sg = sb.class("StateGame")
        sg.update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function() end
        gsm.current_state_name = function() return "X" end
        gsm.destroy = function() end
        -- Tick 1: load fails -> no manager, but wrapping still proceeds.
        bsr._state_update(bsr)
        runner.assert_eq(0, news, "manager not created on failed tick")
        runner.assert_eq(1, load_attempts, "load attempted on tick 1")
        -- Tick 2: load succeeds -> manager created exactly once.
        bsr._state_update(bsr)
        runner.assert_eq(1, news, "manager created once on the successful tick")
        runner.assert_eq(2, load_attempts, "load re-attempted on tick 2 (retry)")
        -- Tick 3: completed -> no further attempts.
        bsr._state_update(bsr)
        runner.assert_eq(2, load_attempts, "completed flag stops further load attempts")
        runner.assert_eq(1, news, "no re-creation after completion")
    end)

    runner.register("lifecycle: bootstrap completion is idempotent — completed flag short-circuits", function()
        -- Once all steps complete, later _state_update ticks are cheap: no
        -- extra load_module calls, no re-wrapping.
        local load_calls = 0
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                load_calls = load_calls + 1
                return { new = function()
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        local sg = sb.class("StateGame")
        sg.update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function() end
        gsm.current_state_name = function() return "X" end
        gsm.destroy = function() end
        bsr._state_update(bsr)  -- completes everything
        runner.assert_eq(1, load_calls, "one load on the completing tick")
        bsr._state_update(bsr)  -- short-circuit
        bsr._state_update(bsr)  -- short-circuit
        runner.assert_eq(1, load_calls, "completed flag prevents further loads")
    end)

    runner.register("lifecycle: unresolved CLASS sentinel does not fool rawget readiness checks", function()
        -- CLASS returns the name string for unresolved classes (the DMF compat
        -- sentinel). The lifecycle uses rawget for readiness, which bypasses
        -- the metatable — so an unresolved class is still treated as absent,
        -- and the bootstrap logs + retries rather than wrapping a string.
        local logged = {}
        local sb = setup(function(msg) table.insert(logged, msg) end)
        sb.Mods.coordinate_bootstrap()  -- installs class wrapper + CLASS sentinel
        -- StateGame is unresolved: CLASS.StateGame is the sentinel string,
        -- but rawget must be nil.
        runner.assert_eq("StateGame", sb.CLASS.StateGame,
            "CLASS.StateGame is the sentinel string before registration")
        runner.assert_nil(rawget(sb.CLASS, "StateGame"),
            "rawget bypasses the sentinel -> nil (absent)")
        -- Drive a boot: StateGame/GSM unresolved -> the bootstrap must log them
        -- as missing, NOT mistake the sentinel string for a real class.
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            return { new = function()
                return { update = function() end, on_game_state_changed = function() end }
            end }
        end
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)
        local sg_missing_logged = false
        for _, line in ipairs(logged) do
            if line:find("StateGame") then sg_missing_logged = true; break end
        end
        runner.assert_eq(true, sg_missing_logged,
            "StateGame must be logged as missing despite the sentinel (rawget = nil)")
    end)

    -- ---------------------------------------------------------------------
    -- Vanilla degradation
    -- ---------------------------------------------------------------------

    runner.register("lifecycle: missing StateGame at bootstrap -> logged + no crash", function()
        local logged = {}
        local sb = setup(function(msg) table.insert(logged, msg) end)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        -- NOTE: StateGame not declared. _ = mg unused.
        local ok, err = pcall(function() bsr._state_update(bsr) end)
        runner.assert_eq(true, ok, "bootstrap must not crash when StateGame is missing: " .. tostring(err))
        runner.assert_truthy(#logged >= 1, "missing StateGame must be logged")
        local sg_logged = false
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("StateGame", 1, true) then
                sg_logged = true; break
            end
        end
        runner.assert_truthy(sg_logged, "a log line names StateGame")
    end)

    runner.register("lifecycle: missing GameStateMachine at bootstrap -> logged + no crash", function()
        local logged = {}
        local sb = setup(function(msg) table.insert(logged, msg) end)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        -- Declare StateGame but NOT GameStateMachine.
        local sg = sb.class("StateGame")
        sg.update = function() end
        local ok, err = pcall(function() bsr._state_update(bsr) end)
        runner.assert_eq(true, ok, "must not crash when GameStateMachine missing: " .. tostring(err))
        local gsm_logged = false
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("GameStateMachine", 1, true) then
                gsm_logged = true; break
            end
        end
        runner.assert_truthy(gsm_logged, "a log line names GameStateMachine")
    end)

    runner.register("lifecycle: mod_manager load failure -> logged + no crash", function()
        local logged = {}
        local sb = setup(function(msg) table.insert(logged, msg) end)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name) return nil end  -- load fails
        sb.Mods.coordinate_bootstrap()
        local ok = pcall(function() bsr._state_update(bsr) end)
        runner.assert_eq(true, ok, "must not crash when mod_manager fails to load")
        runner.assert_truthy(logged[1]:find("mod_manager") ~= nil)
    end)

    runner.register("lifecycle: bootstrap error caught + logged (not propagated)", function()
        -- The bootstrap section is pcall'd, so an error inside it logs and the
        -- engine continues. The original _state_update has already run.
        local logged = {}
        local orig_ran = false
        local sb = setup(function(msg) table.insert(logged, msg) end)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() orig_ran = true end
        sb.Mods.load_module = function(name) error("induced load failure") end
        sb.Mods.coordinate_bootstrap()
        local ok, err = pcall(function() bsr._state_update(bsr) end)
        runner.assert_eq(true, ok, "bootstrap error must be caught, not propagated")
        runner.assert_eq(true, orig_ran, "original still ran first")
        runner.assert_truthy(logged[1]:find("bootstrap failed") ~= nil,
            "log must identify the bootstrap failure")
    end)

    runner.register("lifecycle: original _state_update error is NOT swallowed", function()
        -- The original engine function's errors propagate (no pcall around it).
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() error("engine boom") end
        sb.Mods.load_module = function(name)
            return { new = function() return { update = function() end, on_game_state_changed = function() end } end }
        end
        sb.Mods.coordinate_bootstrap()
        local ok, err = pcall(function() bsr._state_update(bsr) end)
        runner.assert_eq(false, ok, "original engine error must propagate")
        runner.assert_truthy(tostring(err):find("engine boom") ~= nil, "engine error preserved")
    end)

    -- ---------------------------------------------------------------------
    -- No loadstring-driven hook surface
    -- ---------------------------------------------------------------------

    runner.register("lifecycle: no Mods.hook / deferred-hook queue surface", function()
        local sb = setup()
        runner.assert_nil(sb.Mods.hook)
        runner.assert_nil(sb.Mods._deferred_hooks)
        runner.assert_nil(sb._G.MODS_HOOKS)
        runner.assert_nil(sb._G.MODS_HOOKS_BY_FILE)
    end)

    -- ---------------------------------------------------------------------
    -- destroy wrapper — final state-exit dispatch before destruction
    --
    -- Contract: when a GameStateMachine with a current named state is destroyed,
    -- exactly one on_game_state_changed("exit", name, object) is dispatched for
    -- that final state (if not already exited) BEFORE the original destroy, with
    -- per-state-machine dedup against _change_state. Original return values +
    -- errors are preserved; callback failures are isolated; missing destroy
    -- degrades without blocking the other wraps.
    -- ---------------------------------------------------------------------

    runner.register("lifecycle: destroy dispatches a final exit BEFORE the original destroy", function()
        local timeline = {}
        local sb, gsm = setup_destroy({
            on_gsc = function(status, sname)
                table.insert(timeline, "mod:gsc:" .. status .. ":" .. tostring(sname))
            end,
            destroy_fn = function(self) table.insert(timeline, "engine:destroy") end,
        })
        local inst = setmetatable({ _state = { name = "StateMainMenu" } }, { __index = gsm })
        inst:destroy()
        runner.assert_eq({ "mod:gsc:exit:StateMainMenu", "engine:destroy" }, timeline,
            "final exit must dispatch BEFORE the original destroy")
    end)

    runner.register("lifecycle: destroy forwards exit status + name + exact state object identity", function()
        local recorded = {}
        local state_obj = { name = "StateIngame", marker = {} }
        local sb, gsm = setup_destroy({
            on_gsc = function(status, sname, sobj)
                table.insert(recorded, { status = status, name = sname, obj = sobj })
            end,
        })
        local inst = setmetatable({ _state = state_obj }, { __index = gsm })
        inst:destroy()
        runner.assert_eq(1, #recorded, "exactly one exit dispatched")
        runner.assert_eq("exit", recorded[1].status)
        runner.assert_eq("StateIngame", recorded[1].name)
        runner.assert_eq(state_obj, recorded[1].obj,
            "the exact state object is forwarded (identity)")
    end)

    runner.register("lifecycle: destroy with no current state dispatches no exit", function()
        local count = 0
        local sb, gsm = setup_destroy({
            on_gsc = function() count = count + 1 end,
        })
        local inst = setmetatable({}, { __index = gsm })  -- no _state
        inst:destroy()
        runner.assert_eq(0, count, "no exit when there is no current state")
    end)

    runner.register("lifecycle: destroy with no current_state_name dispatches no exit gracefully", function()
        -- Graceful degradation: if the engine build doesn't expose
        -- current_state_name(), destroy dispatches no exit, and the original
        -- destroy still runs unchanged.
        local gsc_called = false
        local engine_ran = false
        local sb = mock.new_sandbox()
        sb.Mods = {}
        mock.attach_logger(sb)
        sb.Managers = {}
        sb.__print = function() end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function() end,
                        on_game_state_changed = function() gsc_called = true end,
                    }
                end }
            end
        end
        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.class("StateGame").update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, new_name) self._state = { name = new_name } end
        -- NOTE: no current_state_name defined on this GameStateMachine.
        gsm.destroy = function(self) engine_ran = true end
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)
        local inst = setmetatable({ _state = { name = "X" } }, { __index = gsm })
        inst:destroy()
        runner.assert_eq(true, engine_ran, "original destroy still runs")
        runner.assert_eq(false, gsc_called,
            "no exit dispatch when current_state_name is absent")
    end)

    runner.register("lifecycle: destroy callback failure isolated; original destroy still runs", function()
        local engine_ran = false
        local logged = {}
        local sb, gsm = setup_destroy({
            print_fn = function(m) table.insert(logged, m) end,
            on_gsc = function() error("mod callback boom") end,
            destroy_fn = function(self) engine_ran = true end,
        })
        local inst = setmetatable({ _state = { name = "StateX" } }, { __index = gsm })
        local ok = pcall(function() inst:destroy() end)
        runner.assert_eq(true, ok, "destroy must not propagate the callback error")
        runner.assert_eq(true, engine_ran, "original destroy runs despite the callback error")
        local found = false
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("final state exit drive failed", 1, true) then
                found = true; break
            end
        end
        runner.assert_truthy(found, "callback failure is logged")
    end)

    runner.register("lifecycle: original destroy error propagates (not swallowed)", function()
        local sb, gsm = setup_destroy({
            destroy_fn = function(self) error("engine destroy boom") end,
        })
        local inst = setmetatable({ _state = { name = "StateX" } }, { __index = gsm })
        local ok, err = pcall(function() inst:destroy() end)
        runner.assert_eq(false, ok, "original destroy error must propagate")
        runner.assert_truthy(tostring(err):find("engine destroy boom") ~= nil,
            "engine error preserved")
    end)

    runner.register("lifecycle: destroy preserves return values with embedded/trailing nils", function()
        local sb, gsm = setup_destroy({
            destroy_fn = function(self) return "x", nil, "y", nil end,
        })
        local inst = setmetatable({ _state = { name = "StateX" } }, { __index = gsm })
        local r1, r2, r3, r4, r5 = inst:destroy()
        runner.assert_eq("x", r1)
        runner.assert_nil(r2, "embedded nil at slot 2 preserved")
        runner.assert_eq("y", r3)
        runner.assert_nil(r4, "trailing nil at slot 4 preserved")
        runner.assert_nil(r5, "nothing beyond slot 4")
        runner.assert_eq(4, select("#", inst:destroy()),
            "select('#') reports 4 returns despite the nils")
    end)

    runner.register("lifecycle: destroy that internally _change_states produces exactly ONE final exit", function()
        -- A destroy that internally changes state must not
        -- cause a duplicate exit. The destroy wrapper exits the current state,
        -- then the original destroy's internal _change_state would normally also
        -- exit it — the shared dedup (_claim_exit) suppresses the duplicate.
        local exits = 0
        local enters = 0
        local sb = mock.new_sandbox()
        sb.Mods = {}
        mock.attach_logger(sb)
        sb.Managers = {}
        sb.__print = function() end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function() end,
                        on_game_state_changed = function(self, status)
                            if status == "exit" then exits = exits + 1
                            elseif status == "enter" then enters = enters + 1 end
                        end,
                    }
                end }
            end
        end
        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.class("StateGame").update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, new_name) self._state = { name = new_name } end
        gsm.current_state_name = function(self) return self._state and self._state.name or nil end
        -- The original destroy internally calls _change_state (which the
        -- _change_state wrapper would normally exit-dispatch for the outgoing state).
        gsm.destroy = function(self, ...) self:_change_state("StateExit") end
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)
        local inst = setmetatable({ _state = { name = "StateMainMenu" } }, { __index = gsm })
        inst:destroy()
        runner.assert_eq(1, exits,
            "exactly ONE exit despite destroy internally _change_state-ing (dedup)")
    end)

    runner.register("lifecycle: an already-exited state is not redispatched by destroy", function()
        -- After _change_state exits state A and transitions to B, destroying the
        -- machine dispatches exactly one exit for B; A is not redispatched.
        local exits = {}
        local sb = mock.new_sandbox()
        sb.Mods = {}
        mock.attach_logger(sb)
        sb.Managers = {}
        sb.__print = function() end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                return { new = function()
                    return {
                        update = function() end,
                        on_game_state_changed = function(self, status, sname)
                            if status == "exit" then table.insert(exits, sname) end
                        end,
                    }
                end }
            end
        end
        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.class("StateGame").update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, new_name) self._state = { name = new_name } end
        gsm.current_state_name = function(self) return self._state and self._state.name or nil end
        gsm.destroy = function(self, ...) end
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)
        local inst = setmetatable({ _state = { name = "StateA" } }, { __index = gsm })
        inst:_change_state("StateB")  -- exits A, enters B
        runner.assert_eq({ "StateA" }, exits, "_change_state exited A")
        inst:destroy()  -- should exit B (current), NOT re-exit A
        runner.assert_eq({ "StateA", "StateB" }, exits,
            "destroy dispatches exactly one exit for the current state B; A not redispatched")
    end)

    runner.register("lifecycle: partial bootstrap — destroy absent tick 1, wraps tick 2 without rewrapping", function()
        local news = 0
        local destroy_calls = 0
        local sb = mock.new_sandbox()
        sb.Mods = {}
        mock.attach_logger(sb)
        sb.Managers = {}
        sb.__print = function() end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                return { new = function()
                    news = news + 1
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.class("StateGame").update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, new_name) self._state = { name = new_name } end
        gsm.current_state_name = function(self) return self._state and self._state.name or nil end
        -- Tick 1: no destroy yet. Manager + StateGame + _change_state wrap; destroy missing.
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)
        runner.assert_eq(1, news, "manager created tick 1")
        -- destroy appears between ticks.
        gsm.destroy = function(self, ...) destroy_calls = destroy_calls + 1 end
        -- Tick 2: destroy wraps; manager/StateGame/_change_state NOT re-wrapped.
        bsr._state_update(bsr)
        runner.assert_eq(1, news, "manager still one instance tick 2 (no rewrap)")
        -- Drive destroy: the wrapper dispatches a final exit then calls original once.
        local inst = setmetatable({ _state = { name = "X" } }, { __index = gsm })
        inst:destroy()
        runner.assert_eq(1, destroy_calls, "original destroy called exactly once")
    end)

    runner.register("lifecycle: destroy wrapper installed once across multiple boot ticks (no layering)", function()
        local destroy_calls = 0
        local sb, gsm, bsr = setup_destroy({
            destroy_fn = function(self, ...) destroy_calls = destroy_calls + 1 end,
        })
        -- Extra boot ticks (continued bootstrap / post-reload requires). Each
        -- tick calls advance_bootstrap; bs.destroy_wrapped prevents re-wrapping.
        bsr._state_update(bsr)
        bsr._state_update(bsr)
        local inst = setmetatable({ _state = { name = "X" } }, { __index = gsm })
        inst:destroy()
        runner.assert_eq(1, destroy_calls,
            "one wrapper layer: original destroy called once despite multiple boot ticks")
    end)

    runner.register("lifecycle: absence of destroy degrades without blocking the other wraps", function()
        local sg_update_calls = 0
        local gsm_change_calls = 0
        local logged = {}
        local sb = mock.new_sandbox()
        sb.Mods = {}
        mock.attach_logger(sb)
        sb.Managers = {}
        sb.__print = function(m) table.insert(logged, m) end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                return { new = function()
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        local sg = sb.class("StateGame")
        sg.update = function(self, dt) sg_update_calls = sg_update_calls + 1 end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, ...) gsm_change_calls = gsm_change_calls + 1 end
        gsm.current_state_name = function() return "X" end
        -- NOTE: no destroy method on the GSM.
        sb.Mods.coordinate_bootstrap()
        local ok = pcall(function() bsr._state_update(bsr) end)
        runner.assert_eq(true, ok, "bootstrap must not crash when destroy is absent")
        -- Other wraps still function.
        sg.update(sg, 0.016)
        local inst = setmetatable({ _state = { name = "A" } }, { __index = gsm })
        inst:_change_state("B")
        runner.assert_eq(1, sg_update_calls, "StateGame.update wrapped despite no destroy")
        runner.assert_eq(1, gsm_change_calls, "_change_state wrapped despite no destroy")
        local destroy_logged = false
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("destroy", 1, true) then
                destroy_logged = true; break
            end
        end
        runner.assert_truthy(destroy_logged, "absent destroy is logged (diagnosable)")
    end)

    -- ---------------------------------------------------------------------
    -- StateSplash skip (opt-in via Mods._relay.skip_splash, set by init.lua
    -- from the trampoline-baked RELAY_SKIP_SPLASH global).
    --
    -- Engine contract (scripts/game_states/game/state_splash.lua @ 47379fd):
    --   on_enter sets _creation_context, _next_state = StateTitle,
    --   _next_state_params = params, params.skip_title_screen_on_invite = true;
    --   computes should_skip via a LOCAL _should_skip() predicate; if true sets
    --   _continue = true; else opens splash_view + registers an event.
    --   update returns _next_state, _next_state_params when _continue.
    --   on_exit closes the view ONLY when not _should_skip.
    --
    -- The wrap takes the engine's OWN skip branch cleanly (sets the same init
    -- fields + skip flags, does NOT call the original on_enter) so the view is
    -- never opened. StateTitle is resolved via Mods.original_require.
    -- ---------------------------------------------------------------------

    -- Full-bootstrap helper for splash tests. Sets up the coordinator + BSR
    -- wrap + manager + StateGame + GSM (with destroy) AND the splash opt-in,
    -- so advance_bootstrap can complete all 5 steps. The BSR wrap is installed
    -- (second coordinate_bootstrap) so a test's bsr._state_update(bsr) tick
    -- drives advance_bootstrap. StateSplash is NOT declared here — tests
    -- declare it (or not) before the boot tick. opts.state_title customizes
    -- the fake StateTitle returned by Mods.original_require. Returns sb, bsr,
    -- fake_state_title.
    local function setup_splash(opts)
        opts = opts or {}
        local sb = mock.new_sandbox()
        sb.Mods = {}
        sb.Mods._relay = { skip_splash = true }  -- the opt-in (init.lua sets this)
        mock.attach_logger(sb)  -- adds log_<level> alongside skip_splash
        sb.Mods._relay.version = "0.3.0-beta.2"
        sb.Crashify = { print_property = function() end }
        sb.Managers = {}
        sb.__print = opts.print_fn or function() end
        sb.class = function(name) return { name = name } end
        -- Mods.original_require returns the fake StateTitle (cached, like the
        -- engine's package.loaded). state_splash.lua requires it at module top.
        local fake_state_title = opts.state_title or { name = "StateTitle" }
        sb.Mods.original_require = function(path)
            if path == "scripts/game_states/game/state_title" then
                return fake_state_title
            end
            return nil
        end
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                return {
                    new = function()
                        return {
                            update = function() end,
                            on_game_state_changed = function() end,
                        }
                    end,
                }
            end
        end
        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        sb.Mods.coordinate_bootstrap()  -- installs class wrapper
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.class("StateGame").update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, new_name) self._state = { name = new_name } end
        gsm.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        gsm.destroy = function(self, ...) end
        sb.Mods.coordinate_bootstrap()  -- wraps BSR (now that it exists)
        return sb, bsr, fake_state_title
    end

    -- Build a fake StateSplash class matching the engine contract. The view
    -- state table tracks open/close + event register/unregister so tests can
    -- assert the view lifecycle is consistent (no orphaned open view). Returns
    -- the class table + the view-state tracker.
    local function make_fake_splash_class()
        local vs = { view_opened = false, view_closed = false,
                     event_registered = false, event_unregistered = false }
        local splash = {}
        splash.on_enter = function(self, parent, params, creation_context)
            self._creation_context = creation_context
            self._next_state = "FAKE_StateTitle_unresolved"
            self._next_state_params = params
            params.skip_title_screen_on_invite = true
            self._should_skip = false
            self._end_duration = 5.0
            vs.view_opened = true
            vs.event_registered = true
        end
        splash.update = function(self, main_dt, main_t)
            local context = self._creation_context
            if context and context.network_receive_function then
                context.network_receive_function(main_dt)
            end
            if context and context.network_transmit_function then
                context.network_transmit_function()
            end
            if self._continue then
                return self._next_state, self._next_state_params
            end
        end
        splash.on_exit = function(self)
            if not self._should_skip then
                vs.event_unregistered = true
                vs.view_closed = true
            end
        end
        return splash, vs
    end

    runner.register("lifecycle: splash step NOT installed when opted out (default)", function()
        -- Default (no Mods._relay.skip_splash): the splash step is never
        -- attempted, StateSplash.on_enter is untouched, and bs.completed still
        -- goes true.
        local sb = setup()  -- default setup: no _relay.skip_splash
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        sb.class("StateGame").update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, n) self._state = { name = n } end
        gsm.current_state_name = function() return "X" end
        gsm.destroy = function() end
        local splash = sb.class("StateSplash")
        local orig_on_enter = function() end
        splash.on_enter = orig_on_enter
        bsr._state_update(bsr)
        runner.assert_eq(orig_on_enter, splash.on_enter,
            "StateSplash.on_enter must be untouched when opted out")
    end)

    runner.register("lifecycle: opted-out splash step does not block bs.completed", function()
        -- With splash opted out, all 4 standard steps complete and the
        -- completed flag short-circuits later ticks (proven by no extra
        -- load_module calls on a second tick).
        local load_calls = 0
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                load_calls = load_calls + 1
                return { new = function()
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb.Mods.coordinate_bootstrap()
        sb.class("StateGame").update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, n) self._state = { name = n } end
        gsm.current_state_name = function() return "X" end
        gsm.destroy = function() end
        sb.class("StateSplash").on_enter = function() end
        bsr._state_update(bsr)  -- completes all 4 steps (splash not attempted)
        runner.assert_eq(1, load_calls, "one load on the completing tick")
        bsr._state_update(bsr)  -- short-circuit
        runner.assert_eq(1, load_calls, "completed flag prevents further loads (splash didn't block)")
    end)

    runner.register("lifecycle: opted-in splash wraps CLASS.StateSplash.on_enter exactly once", function()
        local sb, bsr = setup_splash()
        local splash, vs = make_fake_splash_class()
        -- Install the fake splash class into CLASS via the coordinator's class().
        local splash_class = sb.class("StateSplash")
        local orig_on_enter = splash.on_enter
        splash_class.on_enter = orig_on_enter
        bsr._state_update(bsr)  -- wraps on_enter
        runner.assert_truthy(splash_class.on_enter ~= orig_on_enter,
            "StateSplash.on_enter must be wrapped when opted in")
        -- Second boot tick must not re-wrap.
        bsr._state_update(bsr)
        local wrapped_fn = splash_class.on_enter
        bsr._state_update(bsr)
        runner.assert_eq(wrapped_fn, splash_class.on_enter,
            "StateSplash.on_enter wrapped exactly once (no layering)")
    end)

    runner.register("lifecycle: opted-in splash wrap drives StateSplash to StateTitle with consistent view lifecycle", function()
        -- The wrap must take the engine's skip branch cleanly: set _continue,
        -- _next_state = resolved StateTitle, _should_skip = true, and NEVER
        -- open the view. update() returns _next_state, _next_state_params;
        -- on_exit() does nothing (because _should_skip = true).
        local sb, bsr, fake_state_title = setup_splash()
        local splash_class, vs = make_fake_splash_class()
        -- Register StateSplash in CLASS.
        local registered = sb.class("StateSplash")
        registered.on_enter = splash_class.on_enter
        registered.update = splash_class.update
        registered.on_exit = splash_class.on_exit
        bsr._state_update(bsr)  -- wraps on_enter

        -- Drive the wrapped on_enter (the engine calls it when entering StateSplash).
        local splash_inst = setmetatable({}, { __index = registered })
        local params = {}
        local creation_context = { network_receive_function = function() end,
                                   network_transmit_function = function() end }
        splash_inst:on_enter(nil, params, creation_context)

        -- The skip branch must have been taken (not the original on_enter).
        runner.assert_eq(true, splash_inst._continue, "_continue set (skip branch taken)")
        runner.assert_eq(fake_state_title, splash_inst._next_state,
            "_next_state is the resolved StateTitle (via original_require)")
        runner.assert_eq(params, splash_inst._next_state_params, "_next_state_params preserved")
        runner.assert_eq(true, params.skip_title_screen_on_invite,
            "params.skip_title_screen_on_invite set (engine skip-branch init)")
        runner.assert_eq(true, splash_inst._should_skip, "_should_skip = true (on_exit will no-op)")
        runner.assert_eq(false, vs.view_opened,
            "view NEVER opened (original on_enter not called — no flash, no orphan)")
        runner.assert_eq(false, vs.event_registered, "event never registered")

        -- update() must return _next_state, _next_state_params on the first tick.
        local next_state, next_params = splash_inst:update(0.016, 0)
        runner.assert_eq(fake_state_title, next_state, "update returns _next_state")
        runner.assert_eq(params, next_params, "update returns _next_state_params")

        -- on_exit() must do nothing (because _should_skip = true). No close.
        splash_inst:on_exit()
        runner.assert_eq(false, vs.view_closed,
            "on_exit does not close (nothing was opened — consistent lifecycle)")
        runner.assert_eq(false, vs.view_opened,
            "view still never opened after on_exit — no orphaned open view")
    end)

    runner.register("lifecycle: opted-in splash degrades to vanilla when StateTitle unresolved", function()
        -- If Mods.original_require can't resolve StateTitle (engine contract
        -- shift), the wrap logs once and falls back to the original on_enter
        -- (vanilla splash). The view opens as normal.
        local logged = {}
        local sb, bsr = setup_splash({ print_fn = function(m) table.insert(logged, m) end })
        -- Make original_require return nil for StateTitle (contract shift).
        sb.Mods.original_require = function(path) return nil end
        local splash_class, vs = make_fake_splash_class()
        local registered = sb.class("StateSplash")
        registered.on_enter = splash_class.on_enter
        registered.update = splash_class.update
        registered.on_exit = splash_class.on_exit
        bsr._state_update(bsr)  -- wraps on_enter

        local splash_inst = setmetatable({}, { __index = registered })
        local params = {}
        splash_inst:on_enter(nil, params, { network_receive_function = function() end,
                                            network_transmit_function = function() end })

        -- Fallback: the original on_enter ran (view opened, vanilla behavior).
        runner.assert_eq(true, vs.view_opened,
            "original on_enter ran (vanilla fallback when StateTitle unresolved)")
        runner.assert_nil(splash_inst._continue,
            "_continue NOT forced (vanilla splash runs normally)")
        -- StateTitle resolution failure logged once.
        local st_logged = false
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("StateTitle unavailable") then
                st_logged = true; break
            end
        end
        runner.assert_truthy(st_logged, "StateTitle resolution failure logged once")
    end)

    runner.register("lifecycle: opted-in splash step clean degradation when CLASS.StateSplash absent", function()
        -- StateSplash not declared: the step logs once, no crash, the other 4
        -- steps still complete, bs.completed goes true.
        local logged = {}
        local sb, bsr = setup_splash({ print_fn = function(m) table.insert(logged, m) end })
        -- NOTE: StateSplash NOT declared.
        local ok, err = pcall(function() bsr._state_update(bsr) end)
        runner.assert_eq(true, ok, "bootstrap must not crash when StateSplash is absent: " .. tostring(err))
        -- The other 4 steps completed (proven by no extra loads on a later tick).
        local load_calls = 0
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                load_calls = load_calls + 1
                return { new = function()
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        bsr._state_update(bsr)  -- short-circuit if completed; or wraps splash if present
        runner.assert_eq(0, load_calls,
            "completed flag set (4 standard steps done; absent splash didn't block)")
        -- StateSplash missing logged once.
        local splash_logged = false
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("StateSplash") then
                splash_logged = true; break
            end
        end
        runner.assert_truthy(splash_logged, "absent StateSplash is logged (diagnosable)")
    end)

    -- ---------------------------------------------------------------------
    -- Chassis duties (Step 1c): single dmf_adapter module load, adapter
    -- establish (Managers.mod publication + settings restore-if-nil), exactly
    -- one io-observer registration under any manager, and the process-lifetime
    -- Crashify version publication (attempt at creation, retry on the
    -- StateGame.update wrap).
    -- ---------------------------------------------------------------------

    -- Full-boot helper for the chassis-duty tests: coordinator + BSR wrap + one
    -- advance tick with StateGame/GSM declared so the bootstrap completes on
    -- that tick. The manager comes from the sandbox's (possibly overridden)
    -- load_module fake. Returns (bsr, sg).
    local function setup_booted(sb)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        local sg = sb.class("StateGame")
        sg.update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, n) self._state = { name = n } end
        gsm.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        gsm.destroy = function() end
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)
        return bsr, sg
    end

    runner.register("lifecycle: chassis + real built-in manager -> exactly one io observer + version precedes mod keys", function()
        -- Full-real integration: real lifecycle + real dmf_adapter + real
        -- mod_manager. The built-in's init constructs its own adapter (for its
        -- per-mod driving); the chassis Step 1c must use THAT instance for
        -- establish + register, so exactly one io observer registers per
        -- process no matter how many boot/update ticks run.
        local sb = mock.new_sandbox()
        sb.Mods = { file = {} }
        mock.attach_logger(sb)
        sb.Mods._relay.version = "0.4.0-test"
        local add_calls = 0
        sb.Mods.file.add_observer = function(fn) add_calls = add_calls + 1 end
        sb.Mods.file.read_content_to_table = function(path)
            runner.assert_eq("mods.lst", path)
            return { "some_dmf_mod" }
        end
        sb.Mods.file.exec_with_return = function(path)
            if path == "some_dmf_mod/some_dmf_mod.mod" then
                return { run = function() end }  -- DMF-driven (nil result)
            end
            return false
        end
        local crash_calls = {}
        sb.Crashify = {
            print_property = function(key, value)
                crash_calls[#crash_calls + 1] = { key, value }
            end,
            remove_print_property = function() end,
        }
        sb.Keyboard = {
            button_index = function() return 1 end,
            pressed = function() return false end,
            button = function() return 0 end,
        }
        sb.Managers = {}
        sb.__print = function() end
        -- class usable by the real mod_manager (declares class("ModManager")).
        sb.class = function(name)
            local meta = { name = name }
            meta.__index = meta
            meta.new = function(self, ...)
                local inst = setmetatable({}, meta)
                if meta.init then meta.init(inst, ...) end
                return inst
            end
            return meta
        end
        sb.Mods.load_module = function(name)
            return mock.run_module(name, sb)
        end
        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)  -- chassis loads dmf_adapter once here

        local bsr, sg = setup_booted(sb)
        local mm = sb.Managers.mod
        runner.assert_not_nil(mm, "the real built-in manager was created")
        runner.assert_not_nil(rawget(mm, "_adapter"),
            "the built-in constructed its own adapter instance")
        runner.assert_eq(false, mm._settings.developer_mode,
            "chassis establish restored _settings (default false)")
        runner.assert_eq(1, add_calls,
            "exactly one io observer registered (chassis used the manager's adapter)")

        -- The version property published once at creation, BEFORE any per-mod
        -- key from the load pass. The pass is phased (anchor tick, then one
        -- entry per tick), so drive StateGame.update until the manager done.
        local sg_ticks = 0
        repeat
            sg.update(sg, 0.016)
            sg_ticks = sg_ticks + 1
        until mm._state == "done" or sg_ticks > 100
        runner.assert_eq("done", mm._state, "the real manager completed its load pass")
        runner.assert_eq(2, sg_ticks, "1-entry phased pass: anchor tick + entry tick")
        runner.assert_eq({ { "ModRelay:Version", "0.4.0-test" },
                           { "Mod:some_dmf_mod", true } }, crash_calls,
            "version precedes per-mod keys; one of each")

        -- Later ticks (boot + update) register/publish nothing further.
        bsr._state_update(bsr)
        sg.update(sg, 0.016)
        runner.assert_eq(1, add_calls, "observer count stays one across later ticks")
        runner.assert_eq(2, #crash_calls, "no further property publications")
    end)

    runner.register("lifecycle: chassis establish restores settings-if-nil for a manager that set none", function()
        local sb = setup()
        local mgr
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    mgr = { update = function() end, on_game_state_changed = function() end }
                    return mgr
                end }
            end
        end
        setup_booted(sb)
        runner.assert_eq(mgr, sb.Managers.mod, "the alternate manager occupies the slot")
        runner.assert_type("table", mgr._settings,
            "chassis establish restored _settings for a manager that set none")
        runner.assert_eq(false, mgr._settings.developer_mode)
        runner.assert_nil(rawget(mgr, "_adapter"),
            "the chassis adapter instance is NOT stored on the manager")
    end)

    runner.register("lifecycle: chassis establish is a no-op for a manager that set its own _settings", function()
        local sb = setup()
        local own_settings = { developer_mode = true, log_level = 3 }
        local mgr
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    mgr = {
                        _settings = own_settings,
                        update = function() end,
                        on_game_state_changed = function() end,
                    }
                    return mgr
                end }
            end
        end
        setup_booted(sb)
        runner.assert_eq(own_settings, mgr._settings,
            "a manager-set _settings keeps its identity (restore-if-nil only)")
        runner.assert_eq(true, mgr._settings.developer_mode)
        runner.assert_eq(3, mgr._settings.log_level, "unrelated fields untouched")
    end)

    runner.register("lifecycle: a transient Step-1c failure retries without double observer registration", function()
        -- The manager exposes a shape-compatible _adapter (the built-in path).
        -- Its establish raises on the first attempt: the boot wrapper contains
        -- + logs the failure, creation is NOT redone, and the retry tick
        -- re-runs the duties — register fires only after establish succeeds,
        -- exactly once.
        local logged = {}
        local sb = setup(function(m) table.insert(logged, m) end)
        local establish_calls, register_calls = 0, 0
        sb.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return {
                        _adapter = {
                            establish = function(self)
                                establish_calls = establish_calls + 1
                                if establish_calls == 1 then
                                    error("transient establish boom")
                                end
                            end,
                            register_io_observer = function(self)
                                register_calls = register_calls + 1
                            end,
                        },
                        update = function() end,
                        on_game_state_changed = function() end,
                    }
                end }
            end
        end
        local bsr, sg = setup_booted(sb)
        runner.assert_eq(1, establish_calls, "first tick attempted establish")
        runner.assert_eq(0, register_calls, "register never ran past the failed establish")
        runner.assert_not_nil(sb.Managers.mod, "the manager itself was created once")
        local failed_logged = false
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("bootstrap failed", 1, true) then
                failed_logged = true; break
            end
        end
        runner.assert_truthy(failed_logged, "the Step-1c failure is logged + contained")

        -- Retry tick: establish succeeds, register fires exactly once, and the
        -- bootstrap completes (a third tick short-circuits — no more attempts).
        bsr._state_update(bsr)
        runner.assert_eq(2, establish_calls, "retry tick re-ran establish")
        runner.assert_eq(1, register_calls, "register fired exactly once")
        bsr._state_update(bsr)
        runner.assert_eq(2, establish_calls, "completed flag stops further duty attempts")
        runner.assert_eq(1, register_calls)
    end)

    runner.register("lifecycle: version published exactly once at creation when Crashify present", function()
        local sb = setup()
        local prints = {}
        sb.Crashify = {
            print_property = function(key, value)
                prints[#prints + 1] = { key, value }
            end,
        }
        sb.Mods._relay.version = "9.9.9-test"
        local bsr, sg = setup_booted(sb)
        runner.assert_eq({ { "ModRelay:Version", "9.9.9-test" } }, prints,
            "published once at manager creation")
        runner.assert_eq(true, sb.Mods._relay.crashify_version_published)
        -- Boot + update ticks never re-publish.
        bsr._state_update(bsr)
        sg.update(sg, 0.016)
        sg.update(sg, 0.016)
        runner.assert_eq(1, #prints, "the flag short-circuits all later ticks")
    end)

    runner.register("lifecycle: version publication retries across update ticks when Crashify appears late", function()
        local logged = {}
        local sb = setup(function(m) table.insert(logged, m) end)
        sb.Crashify = nil  -- absent at creation
        local prints = {}
        local bsr, sg = setup_booted(sb)
        runner.assert_eq(0, #prints, "nothing published while Crashify is absent")
        sg.update(sg, 0.016)
        sg.update(sg, 0.016)
        runner.assert_eq(0, #prints, "contained retries publish nothing while absent")
        local unavailable_logs = 0
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("Crashify unavailable", 1, true) then
                unavailable_logs = unavailable_logs + 1
            end
        end
        runner.assert_eq(1, unavailable_logs, "the unavailable case logs once")

        -- Crashify appears: the next update tick publishes, exactly once.
        sb.Crashify = {
            print_property = function(key, value)
                prints[#prints + 1] = { key, value }
            end,
        }
        sg.update(sg, 0.016)
        runner.assert_eq({ { "ModRelay:Version", "0.3.0-beta.2" } }, prints,
            "late Crashify publishes on the next update tick")
        sg.update(sg, 0.016)
        bsr._state_update(bsr)
        runner.assert_eq(1, #prints, "still exactly one publication after success")
    end)

    runner.register("lifecycle: a throwing Crashify.print_property never breaks bootstrap or update", function()
        local logged = {}
        local sb, manager_updates = setup(function(m) table.insert(logged, m) end)
        local prints = {}
        sb.Crashify = {
            print_property = function() error("crashify boom") end,
        }
        -- Install the counting engine update BEFORE the wrap (it becomes the
        -- wrapped original the bootstrap calls after m:update).
        local engine_updates = 0
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        local sg = sb.class("StateGame")
        sg.update = function() engine_updates = engine_updates + 1 end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, n) self._state = { name = n } end
        gsm.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        gsm.destroy = function() end
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)  -- completes: the Step-1c throw is contained
        runner.assert_not_nil(sb.Managers.mod,
            "the throw was contained: manager creation + duties completed")

        -- The update wrap retries publication before m:update; a throwing
        -- print_property must not break the wrap, the manager update, or the
        -- engine update.
        local ok, err = pcall(function() sg.update(sg, 0.016) end)
        runner.assert_eq(true, ok, "update must not propagate the Crashify throw: " .. tostring(err))
        runner.assert_eq(1, engine_updates, "engine update still ran")
        runner.assert_eq(0.016, manager_updates[1], "manager update still ran")
        runner.assert_eq(0, #prints, "nothing published while print_property throws")
        local throw_logs = 0
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("version publication failed", 1, true) then
                throw_logs = throw_logs + 1
            end
        end
        runner.assert_eq(1, throw_logs, "the throw case logs once")

        -- Recovery: print_property stops raising; a later tick publishes.
        sb.Crashify = {
            print_property = function(key, value)
                prints[#prints + 1] = { key, value }
            end,
        }
        sg.update(sg, 0.016)
        runner.assert_eq({ { "ModRelay:Version", "0.3.0-beta.2" } }, prints,
            "publication succeeds once print_property recovers")
        sg.update(sg, 0.016)
        runner.assert_eq(1, #prints)
    end)

    runner.register("lifecycle: an invalid private version logs once and never publishes", function()
        local logged = {}
        local sb = setup(function(m) table.insert(logged, m) end)
        sb.Mods._relay.version = "bad\nversion"  -- control byte -> invalid
        local prints = {}
        sb.Crashify = {
            print_property = function(key, value)
                prints[#prints + 1] = { key, value }
            end,
        }
        local bsr, sg = setup_booted(sb)
        runner.assert_not_nil(sb.Managers.mod, "the invalid version never blocks bootstrap")
        sg.update(sg, 0.016)
        sg.update(sg, 0.016)
        runner.assert_eq(0, #prints, "an invalid version is never published")
        runner.assert_nil(sb.Mods._relay.crashify_version_published)
        local invalid_logs = 0
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find("version crash metadata unavailable", 1, true) then
                invalid_logs = invalid_logs + 1
            end
        end
        runner.assert_eq(1, invalid_logs, "the invalid-version case logs once")
    end)

    -- ---------------------------------------------------------------------
    -- Throttled containment-error logging (log_contained_error). The five
    -- chassis containment sites coalesce same-key recurrences: first
    -- occurrence immediate (byte-identical plain ERROR), recurrences within
    -- 10s counted silently, first recurrence after the window logs with a
    -- suppressed-count suffix, keys are per-site + per-error-text, and a
    -- missing/broken clock degrades to logging every occurrence.
    -- ---------------------------------------------------------------------

    -- Full boot with a mock clock on Mods.lua.os.time (read at CALL time by
    -- the helper; advance rec.clock.now between drives) and a manager whose
    -- update / on_game_state_changed raise whatever the test stages on
    -- mgr.update_err / mgr.gsc_exit_err / mgr.gsc_enter_err (error level 0 so
    -- the error value is exactly the staged string — no position prefix).
    -- Errors use error(msg, 0) so tostring(err) is byte-exact for assertions.
    local function setup_throttled(opts)
        opts = opts or {}
        local clock = { now = opts.t0 or 1000 }
        local logged = {}
        local sb = mock.new_sandbox()
        sb.Mods = {}
        mock.attach_logger(sb)
        sb.Mods._relay.version = "0.3.0-beta.2"
        sb.Crashify = { print_property = function() end }
        sb.Managers = {}
        sb.__print = function(m) logged[#logged + 1] = m end
        if opts.no_clock then
            sb.Mods.lua = {}  -- no os surface -> unthrottled degradation
        else
            sb.Mods.lua = { os = { time = function() return clock.now end } }
        end
        sb.class = function(name) return { name = name } end
        local mgr = { update_err = nil, gsc_exit_err = nil, gsc_enter_err = nil }
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                return {
                    new = function()
                        return {
                            update = function()
                                if mgr.update_err then error(mgr.update_err, 0) end
                            end,
                            on_game_state_changed = function(_, status)
                                if status == "exit" and mgr.gsc_exit_err then
                                    error(mgr.gsc_exit_err, 0)
                                elseif status == "enter" and mgr.gsc_enter_err then
                                    error(mgr.gsc_enter_err, 0)
                                end
                            end,
                        }
                    end,
                }
            end
        end
        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        local sg = sb.class("StateGame")
        sg.update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, n) self._state = { name = n } end
        gsm.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        gsm.destroy = function() end
        sb.Mods.coordinate_bootstrap()
        bsr._state_update(bsr)  -- completes the bootstrap (wraps steps 2-4)
        local rec = {
            sb = sb, clock = clock, logged = logged,
            sg = sg, gsm = gsm, bsr = bsr, mgr = mgr,
        }
        -- Drive one contained update failure (the wrapped StateGame.update
        -- pcalls Managers.mod:update; the raise must never escape).
        function rec.drive_update()
            local ok = pcall(function() sg.update(sg, 0.016) end)
            runner.assert_eq(true, ok, "the update-wrap containment must hold")
        end
        -- Drive one contained state-transition failure (exit dispatch before
        -- the original _change_state, enter dispatch after it; both pcalled).
        function rec.drive_transition()
            local inst = setmetatable({ _state = { name = "From" } },
                { __index = gsm })
            local ok = pcall(function() inst:_change_state("To") end)
            runner.assert_eq(true, ok, "the change-state-wrap containment must hold")
        end
        return rec
    end

    -- The ERROR messages in order (stripped of the "ERROR [mod_loader] "
    -- prefix the attached logger adds).
    local function error_messages(logged)
        local out = {}
        for _, line in ipairs(logged) do
            local msg = tostring(line):match("^ERROR %[mod_loader%] (.*)$")
            if msg then out[#out + 1] = msg end
        end
        return out
    end

    runner.register("lifecycle: containment error — first occurrence logs immediately (exact line)", function()
        local rec = setup_throttled()
        rec.mgr.update_err = "boom"
        rec.drive_update()
        runner.assert_eq({ "Managers.mod:update failed: boom" }, error_messages(rec.logged),
            "the first occurrence logs the plain, un-suffixed line")
    end)

    runner.register("lifecycle: containment error — identical recurrences within the window are counted, not logged", function()
        local rec = setup_throttled()
        rec.mgr.update_err = "boom"
        rec.drive_update()
        rec.drive_update()
        rec.drive_update()
        runner.assert_eq({ "Managers.mod:update failed: boom" }, error_messages(rec.logged),
            "recurrences inside the 10s window log nothing (counted only)")
    end)

    runner.register("lifecycle: containment error — post-interval recurrence logs the suppressed count, then resets", function()
        local rec = setup_throttled()
        rec.mgr.update_err = "boom"
        rec.drive_update()                  -- t0: first occurrence (plain line)
        rec.drive_update()                  -- t0: suppressed (count 1)
        rec.clock.now = rec.clock.now + 11
        rec.drive_update()                  -- t0+11: logs the count, resets
        rec.drive_update()                  -- t0+11: suppressed (count 1)
        rec.clock.now = rec.clock.now + 11
        rec.drive_update()                  -- t0+22: suffix reflects ONLY post-reset occurrences
        runner.assert_eq({
            "Managers.mod:update failed: boom",
            "Managers.mod:update failed: boom [x2 in the last 10s]",
            "Managers.mod:update failed: boom [x2 in the last 10s]",
        }, error_messages(rec.logged),
            "window-boundary lines carry the since-last-log count (suppressed + current); count resets each time")
    end)

    runner.register("lifecycle: containment error — a different error text at the same site logs immediately", function()
        local rec = setup_throttled()
        rec.mgr.update_err = "boom"
        rec.drive_update()                  -- logs "boom"
        rec.mgr.update_err = "other failure"
        rec.drive_update()                  -- new key -> immediate, inside the window
        runner.assert_eq({
            "Managers.mod:update failed: boom",
            "Managers.mod:update failed: other failure",
        }, error_messages(rec.logged), "a different error text is a new key (logs immediately)")
    end)

    runner.register("lifecycle: containment error — the same error text at different sites logs immediately (per-site keys)", function()
        local rec = setup_throttled()
        rec.mgr.update_err = "boom"
        rec.drive_update()                  -- update site logs "boom"
        rec.mgr.gsc_exit_err = "boom"       -- SAME text, different site
        rec.drive_transition()              -- exit dispatch logs immediately
        rec.mgr.gsc_enter_err = "boom"      -- SAME text, third site
        rec.drive_transition()              -- enter dispatch logs immediately
        runner.assert_eq({
            "Managers.mod:update failed: boom",
            "state exit drive failed: boom",
            "state enter drive failed: boom",
        }, error_messages(rec.logged),
            "keys are per-site: same error text at another containment site logs immediately")
    end)

    runner.register("lifecycle: containment error — no usable clock degrades to logging every occurrence", function()
        local rec = setup_throttled({ no_clock = true })
        rec.mgr.update_err = "boom"
        rec.drive_update()
        rec.drive_update()
        rec.drive_update()
        runner.assert_eq({
            "Managers.mod:update failed: boom",
            "Managers.mod:update failed: boom",
            "Managers.mod:update failed: boom",
        }, error_messages(rec.logged), "no os surface: every occurrence logs")

        -- The helper reads the surface at call time, so each broken shape
        -- degrades the same way: time present but not a function, a raising
        -- time (pcall-protected), and Mods.lua absent entirely.
        rec.sb.Mods.lua = { os = { time = "not a function" } }
        rec.drive_update()
        rec.sb.Mods.lua = { os = { time = function() error("clock boom") end } }
        rec.drive_update()
        rec.sb.Mods.lua = nil
        rec.drive_update()
        runner.assert_eq(6, #error_messages(rec.logged),
            "every degraded occurrence logs; throttling never costs a log line")
    end)

    runner.register("lifecycle: containment error — the 33rd distinct key resets the throttle table", function()
        local rec = setup_throttled()
        local expected = {}
        -- 33 distinct error texts: the first 32 fill the key table; the 33rd
        -- exceeds the cap, dropping the whole table (one DEBUG line) and
        -- starting fresh.
        for i = 1, 33 do
            rec.mgr.update_err = "boom " .. i
            rec.drive_update()
            expected[#expected + 1] = "Managers.mod:update failed: boom " .. i
        end
        -- A recurrence of the FIRST key at the same instant: had the table
        -- survived, this would be suppressed; after the reset it is a fresh
        -- key and logs immediately.
        rec.mgr.update_err = "boom 1"
        rec.drive_update()
        expected[#expected + 1] = "Managers.mod:update failed: boom 1"
        runner.assert_eq(expected, error_messages(rec.logged),
            "all 34 occurrences logged (the reset un-suppressed the old key)")
        local reset_logs = 0
        for _, line in ipairs(rec.logged) do
            if type(line) == "string" and line:find("^DEBUG %[mod_loader%].*throttle") then
                reset_logs = reset_logs + 1
            end
        end
        runner.assert_eq(1, reset_logs, "the table reset is named in exactly one DEBUG line")
    end)
    -- ---------------------------------------------------------------------
    -- Startup trace diagnostics: bootstrap landing lines + FRAME_INDEX-stamped
    -- state-dispatch lines (docs/reference/relay/logging.md).
    -- ---------------------------------------------------------------------

    local function count_lines(logged, sub)
        local n = 0
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find(sub, 1, true) then n = n + 1 end
        end
        return n
    end

    runner.register("lifecycle: bootstrap landings fire once each (not on retries)", function()
        local logged = {}
        local sb, gsm, bsr = setup_destroy({ print_fn = function(m) table.insert(logged, m) end })
        local expected_landings = {
            "bootstrap: manager created",
            "bootstrap: StateGame.update wrapped",
            "bootstrap: GameStateMachine._change_state wrapped",
            "bootstrap: GameStateMachine.destroy wrapped",
        }
        for _, landing in ipairs(expected_landings) do
            runner.assert_eq(1, count_lines(logged, landing),
                "'" .. landing .. "' fires exactly once on the completing pass")
        end
        -- Later ticks are short-circuited by bs.completed: no repeat landings.
        bsr._state_update(bsr)
        bsr._state_update(bsr)
        for _, landing in ipairs(expected_landings) do
            runner.assert_eq(1, count_lines(logged, landing),
                "'" .. landing .. "' never repeats on later ticks")
        end
    end)

    runner.register("lifecycle: splash landing fires once when opted in; never when opted out", function()
        local logged = {}
        local sb, bsr = setup_splash({ print_fn = function(m) table.insert(logged, m) end })
        local registered = sb.class("StateSplash")
        registered.on_enter = function() end
        bsr._state_update(bsr)  -- completes incl. the splash step
        bsr._state_update(bsr)  -- short-circuit
        runner.assert_eq(1, count_lines(logged, "bootstrap: StateSplash.on_enter wrapped"),
            "opted in: exactly one splash landing")

        local logged2 = {}
        local sb2 = setup(function(m) table.insert(logged2, m) end)
        sb2.Mods.coordinate_bootstrap()
        local bsr2 = sb2.class("BootStateRequireGameScripts")
        bsr2._state_update = function() end
        sb2.Mods.load_module = function(name)
            if name == "mod_manager" then
                return { new = function()
                    return { update = function() end, on_game_state_changed = function() end }
                end }
            end
        end
        sb2.Mods.coordinate_bootstrap()
        sb2.class("StateGame").update = function() end
        local gsm2 = sb2.class("GameStateMachine")
        gsm2._change_state = function(self, n) self._state = { name = n } end
        gsm2.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        gsm2.destroy = function() end
        sb2.class("StateSplash").on_enter = function() end
        bsr2._state_update(bsr2)  -- full boot, splash NOT attempted
        runner.assert_eq(0, count_lines(logged2, "StateSplash.on_enter wrapped"),
            "opted out: no splash landing")
    end)

    runner.register("lifecycle: state exit/enter/final-exit lines carry the frame stamp", function()
        local logged = {}
        local sb, gsm, bsr = setup_destroy({ print_fn = function(m) table.insert(logged, m) end })
        sb.FRAME_INDEX = 7
        local inst = setmetatable({ _state = { name = "StateA" } }, { __index = gsm })
        inst:_change_state("StateB")
        runner.assert_eq(1, count_lines(logged, "state exit: StateA tick=0 frame=7"),
            "exit dispatch logs the outgoing state + stamp")
        runner.assert_eq(1, count_lines(logged, "state enter: StateB tick=0 frame=7"),
            "enter dispatch logs the incoming state + stamp")
        inst:destroy()
        runner.assert_eq(1, count_lines(logged, "state exit (final): StateB tick=0 frame=7"),
            "the destroy wrap's final exit logs its own shape + stamp")
        runner.assert_eq(0, count_lines(logged, "state exit (final): StateA"),
            "the already-exited StateA is not redispatched by destroy")
    end)

    runner.register("lifecycle: a skipped exit (no current state) emits no exit line; enter still logs", function()
        local logged = {}
        local sb, gsm, bsr = setup_destroy({ print_fn = function(m) table.insert(logged, m) end })
        sb.FRAME_INDEX = 3
        local inst = setmetatable({}, { __index = gsm })  -- no _state yet
        inst:_change_state("StateFirst")
        runner.assert_eq(0, count_lines(logged, "state exit:"),
            "no outgoing state -> no dispatch -> no success line")
        runner.assert_eq(1, count_lines(logged, "state enter: StateFirst tick=0 frame=3"),
            "enter still dispatches and logs")
    end)

    runner.register("lifecycle: a failed (contained) exit dispatch emits no success line", function()
        local logged = {}
        local sb, gsm, bsr = setup_destroy({
            print_fn = function(m) table.insert(logged, m) end,
            on_gsc = function(status)
                if status == "exit" then error("gsc exit boom") end
            end,
        })
        sb.FRAME_INDEX = 5
        local inst = setmetatable({ _state = { name = "StateA" } }, { __index = gsm })
        local ok = pcall(function() inst:_change_state("StateB") end)
        runner.assert_eq(true, ok, "the dispatch failure is contained")
        runner.assert_eq(1, count_lines(logged, "state exit drive failed"),
            "the contained failure is logged as an ERROR")
        runner.assert_eq(0, count_lines(logged, "state exit: "),
            "a failed exit dispatch emits no success line")
        runner.assert_eq(1, count_lines(logged, "state enter: StateB tick=0 frame=5"),
            "the enter dispatch (which succeeded) still logs")
    end)

    runner.register("lifecycle: a state name with a raising __tostring cannot throw out of the dispatch lines", function()
        -- The dispatch lines interpolate current_state_name()'s return; a
        -- non-string name whose __tostring raises must render as the safe
        -- fallback, never escape the wrap into the engine's state machine.
        -- (The fake on_gsc never touches the name, so only the log line
        -- exercises the toxic value.)
        local logged = {}
        local sb, gsm, bsr = setup_destroy({
            print_fn = function(m) table.insert(logged, m) end,
            on_gsc = function() end,
        })
        sb.FRAME_INDEX = 9
        local toxic = setmetatable({}, { __tostring = function() error("state name boom") end })
        local inst = setmetatable({ _state = { name = toxic } }, { __index = gsm })
        local ok, err = pcall(function() inst:_change_state("StateB") end)
        runner.assert_eq(true, ok, "the exit dispatch line must contain the unprintable name: " .. tostring(err))
        runner.assert_eq(1, count_lines(logged, "state exit: <unprintable error> tick=0 frame=9"),
            "the exit line renders the safe fallback + stamp")
        runner.assert_eq(1, count_lines(logged, "state enter: StateB tick=0 frame=9"),
            "the enter line (plain string name) is unaffected")
        -- The destroy wrap's final-exit line is equally safe.
        inst._state = { name = toxic }
        local ok2, err2 = pcall(function() inst:destroy() end)
        runner.assert_eq(true, ok2, "the final-exit line must contain the unprintable name: " .. tostring(err2))
        runner.assert_eq(1, count_lines(logged, "state exit (final): <unprintable error> tick=0 frame=9"),
            "the final-exit line renders the safe fallback + stamp")
    end)

    -- ---------------------------------------------------------------------
    -- Loader-relative tick counter (the StateBoot.update -> StateGame.update
    -- observation chain; docs/reference/relay/logging.md).
    -- ---------------------------------------------------------------------

    runner.register("lifecycle: StateBoot.update wrap increments the tick once per boot update", function()
        local logged = {}
        local sb = setup(function(m) table.insert(logged, m) end)
        sb.Mods.coordinate_bootstrap()  -- installs the class wrapper
        local boot = sb.class("StateBoot")
        local orig_calls = 0
        boot.update = function(self, dt)
            orig_calls = orig_calls + 1
            return "boot-result", nil, "extra"
        end
        runner.assert_eq(0, sb.Mods._relay._tick, "tick 0 before any engine update (injection epoch)")
        sb.Mods.coordinate_bootstrap()  -- installs the StateBoot.update wrap
        runner.assert_eq(1, count_lines(logged, "bootstrap: StateBoot.update wrapped"),
            "the tick-driver landing fires exactly once")
        runner.assert_eq(0, sb.Mods._relay._tick, "installing the wrap does not itself bump")

        local inst = setmetatable({}, { __index = boot })
        local r1, r2, r3 = inst:update(0.016)
        runner.assert_eq("boot-result", r1, "original first return preserved")
        runner.assert_nil(r2, "embedded nil preserved")
        runner.assert_eq("extra", r3, "trailing value preserved")
        runner.assert_eq(1, sb.Mods._relay._tick, "one engine update observed -> tick 1")
        inst:update(0.016)
        inst:update(0.016)
        runner.assert_eq(3, sb.Mods._relay._tick, "exactly one increment per engine update")
        runner.assert_eq(3, orig_calls, "the original ran once per update (no re-entry)")
        -- Later coordinator calls never re-wrap (no double bump per update).
        sb.Mods.coordinate_bootstrap()
        inst:update(0.016)
        runner.assert_eq(4, sb.Mods._relay._tick)
        runner.assert_eq(4, orig_calls)
        runner.assert_eq(1, count_lines(logged, "bootstrap: StateBoot.update wrapped"),
            "the landing never repeats")
    end)

    runner.register("lifecycle: a throwing StateBoot.update propagates; the boundary was still counted", function()
        local sb = setup()
        sb.Mods.coordinate_bootstrap()
        local boot = sb.class("StateBoot")
        boot.update = function(self, dt) error("boot update boom") end
        sb.Mods.coordinate_bootstrap()
        local inst = setmetatable({}, { __index = boot })
        local ok, err = pcall(function() inst:update(0.016) end)
        runner.assert_eq(false, ok, "original StateBoot.update errors must propagate (no swallow)")
        runner.assert_truthy(tostring(err):find("boot update boom") ~= nil, "engine error preserved")
        runner.assert_eq(1, sb.Mods._relay._tick,
            "the update boundary was entered, so the tick counted it (entry increment, like FRAME_INDEX)")
    end)

    runner.register("lifecycle: StateBoot→StateGame chain — exactly one increment per engine update, no double", function()
        -- Engine-shaped simulation: main.lua's requires register all the
        -- classes before the first update; each simulated engine update
        -- advances FRAME_INDEX (Main.update entry) then drives the CURRENT
        -- state's update. Boot sub-states nest inside StateBoot (its update
        -- drives the boot SM, which ticks BSR); boot completes and StateGame
        -- takes over. The counter must total exactly the number of engine
        -- updates driven.
        local sb = setup()
        sb.Mods.coordinate_bootstrap()  -- installs the class wrapper
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        local boot = sb.class("StateBoot")
        local sg = sb.class("StateGame")
        sg.update = function(self, dt) end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, n) self._state = { name = n } end
        gsm.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        gsm.destroy = function() end
        -- Stamp observed from INSIDE an engine update (post-boundary values).
        local seen_stamp = nil
        local bsr_inst = setmetatable({}, { __index = bsr })
        boot.update = function(self, dt)
            if seen_stamp == nil then
                seen_stamp = sb.Mods._relay.frame_stamp()
            end
            bsr._state_update(bsr_inst)  -- engine-shaped: boot drives its sub-SM
        end
        sb.Mods.coordinate_bootstrap()  -- wraps BSR + the StateBoot tick driver

        runner.assert_eq(" tick=0 frame=?", sb.Mods._relay.frame_stamp(),
            "pre-main.lua moment: tick=0, FRAME_INDEX absent")
        sb.FRAME_INDEX = -1  -- main.lua loaded; still no update has run
        runner.assert_eq(" tick=0 frame=-1", sb.Mods._relay.frame_stamp())

        -- Simulate engine updates: FRAME_INDEX advances at Main.update entry,
        -- then the current state's update runs.
        local function engine_update(inst)
            sb.FRAME_INDEX = sb.FRAME_INDEX + 1
            inst:update(0.016)
        end
        local boot_inst = setmetatable({}, { __index = boot })
        local sg_inst = setmetatable({}, { __index = sg })

        -- Boot phase: 3 updates (the first also completes the bootstrap via
        -- the BSR wrap inside StateBoot.update, installing the StateGame wrap
        -- mid-update — StateGame.update itself does NOT run this update).
        engine_update(boot_inst)
        runner.assert_eq(1, sb.Mods._relay._tick, "first engine update -> tick 1")
        runner.assert_eq(" tick=1 frame=0", seen_stamp,
            "a stamp taken inside the first update sees post-boundary values (tick = frame + 1)")
        engine_update(boot_inst)
        engine_update(boot_inst)
        runner.assert_eq(3, sb.Mods._relay._tick, "three boot updates -> tick 3")

        -- Boot completes; StateGame takes over: 2 more updates.
        engine_update(sg_inst)
        engine_update(sg_inst)
        runner.assert_eq(5, sb.Mods._relay._tick,
            "the chain totals exactly one increment per engine update (3 boot + 2 game = 5)")
        runner.assert_eq(4, sb.FRAME_INDEX, "sanity: 5 updates, FRAME_INDEX -1 -> 4")
    end)

    runner.register("lifecycle: no tick observation while neither chain wrap is installed (0 until the first observable update)", function()
        -- Without CLASS.StateBoot (older-engine/harness shape), the counter
        -- stays 0 until the StateGame wrap's first tick — the epoch is
        -- anchored at injection, never shifted.
        local sb, mu, mg = setup()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        sb.Mods.coordinate_bootstrap()
        runner.assert_eq(0, sb.Mods._relay._tick, "no StateBoot class -> no boot-phase observation")
        bsr._state_update(bsr)  -- boot ticks alone do not bump the counter
        runner.assert_eq(0, sb.Mods._relay._tick,
            "the BSR wrap is not an increment point (only the StateBoot/StateGame update wraps are)")
    end)
end
