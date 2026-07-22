-- test_lifecycle.lua — bootstrap coordinator + boot/state wrapping (src/mod_loader/lifecycle.lua).
--
-- Asserts observable behavior:
--   - coordinator installs class_registry once `class` appears
--   - BootStateRequireGameScripts._state_update wrapped exactly once
--   - original _state_update runs FIRST (its return preserved); bootstrap runs after
--   - bootstrap loads mod_manager + instantiates Managers.mod once
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
        sb.Managers = {}
        sb.__print = print_fn or function() end

        -- fake engine class(): returns a fresh table per name; wrapper stores
        -- it in CLASS[name]. Tests populate the returned tables with methods.
        sb.class = function(name, ...)
            return { name = name }
        end

        -- fake ModManager (loaded by the bootstrap via Mods.load_module).
        -- new() yields an instance whose update/on_game_state_changed are
        -- spies the test can observe.
        local manager_updates = {}
        local manager_gsc = {}
        sb.Mods.load_module = function(name)
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
        sb.Managers = {}
        sb.__print = opts.print_fn or function() end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
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
        runner.assert_truthy(logged[1]:find("StateGame") ~= nil, "log names StateGame")
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
        runner.assert_truthy(logged[1]:find("GameStateMachine") ~= nil, "log names GameStateMachine")
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
    -- destroy wrapper — final state-exit dispatch before destruction (Finding 3)
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
        sb.Managers = {}
        sb.__print = function() end
        sb.class = function(name) return { name = name } end
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
        -- Contract point 9: a destroy that internally changes state must not
        -- cause a duplicate exit. The destroy wrapper exits the current state,
        -- then the original destroy's internal _change_state would normally also
        -- exit it — the shared dedup (_claim_exit) suppresses the duplicate.
        local exits = 0
        local enters = 0
        local sb = mock.new_sandbox()
        sb.Mods = {}
        sb.Managers = {}
        sb.__print = function() end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
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
        -- The original destroy internally calls _change_state (which the Step 3
        -- wrapper would normally exit-dispatch for the outgoing state).
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
        sb.Managers = {}
        sb.__print = function() end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
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
        sb.Managers = {}
        sb.__print = function() end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
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
        sb.Managers = {}
        sb.__print = function(m) table.insert(logged, m) end
        sb.class = function(name) return { name = name } end
        sb.Mods.load_module = function(name)
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
end
