-- test_mod_manager.lua — the loader driver (src/mod_loader/mod_manager.lua).
--
-- Asserts the external behavior contract:
--   - declares class("ModManager") (so CLASS.ModManager.destroy exists for DMF)
--   - generic scan/load/lifecycle behavior is unchanged:
--     - init() SCANs only: reads mods.lst, builds _mods (id/name/handle), no load
--     - missing/empty mods.lst -> empty _mods, no crash
--     - _state nil after init; "done" after first update; written once even if all fail
--     - update(dt) LOADs on first call (per-mod run/init in order), then drives
--     - run() then init() per mod, before the next mod loads
--     - run() failure / missing .mod / bad .mod -> skipped, load continues
--     - run() returning nil -> DMF-driven success (not outer-driven, not a failure)
--     - init() failure -> object not driven
--     - update(dt) fans out to each loaded mod's update; failures isolated
--     - on_game_state_changed forwards status+name+object; failures isolated
--     - destroy() calls on_unload in reverse order; failures isolated
--     - Managers.mod shape: _mods[_mod_load_index].handle resolves per mod during load
--   - the DMF-visible contract fields (_state, _mod_load_index, _settings) are
--     driven through the dmf_adapter; mod_manager itself never writes them
--     directly. The DMF IO adaptation (eight DMFMod:io_* overrides, path
--     construction, debug/error logging, observer timing, installation-aware
--     re-adaptation) is covered in test_dmf_adapter.lua.

local mock = require("mock")

return function(runner)
    -- Build a sandbox with the fakes mod_manager needs: `class` (so it can call
    -- class("ModManager")), Mods.file (read_content_to_table + exec_with_return),
    -- Mods.load_module (so mod_manager.lua can load the dmf_adapter from disk),
    -- Managers, __print. Returns the sandbox + the class registry.
    local function setup(opts)
        opts = opts or {}
        local sb = mock.new_sandbox()

        -- fake class: callable table that records declarations + supports :new
        local registry = { _order = {} }
        local class_tbl
        local function declare(name, ...)
            local meta = { name = name }
            meta.__index = meta
            meta.new = function(self, ...)
                local instance = setmetatable({}, meta)
                if meta.init then meta.init(instance, ...) end
                return instance
            end
            registry[name] = meta
            table.insert(registry._order, name)
            return meta
        end
        class_tbl = setmetatable({ _registry = registry },
            { __call = function(_, ...) return declare(...) end })
        sb.class = class_tbl

        sb.__print = sb.__print or function() end
        sb.Managers = {}

        sb.Mods = { file = {} }

        -- mod_manager.lua loads dmf_adapter.lua via Mods.load_module at module
        -- top. Wire it to the mock's source loader so the real adapter source
        -- runs in the sandbox (the adapter is the DMF boundary; the manager
        -- delegates DMF contract writes/reads to it).
        sb.Mods.load_module = function(name)
            return mock.run_module(name, sb)
        end

        -- A no-op Keyboard so the manager's reload-shortcut poll is silent in
        -- tests that don't exercise keyboard behavior (nothing pressed). The
        -- dedicated hot-reload tests inject a controllable Keyboard instead.
        sb.Keyboard = {
            button_index = function(name)
                if name == "r" then return 1 end
                if name == "left shift" then return 2 end
                if name == "left ctrl" then return 3 end
                return nil
            end,
            pressed = function(i) return false end,
            button = function(i) return 0 end,
        }

        -- The loader's file-execution observer hook (file.lua provides this in
        -- production; the isolated test stubs it since mod_manager only
        -- registers an observer, it doesn't drive file exec here).
        sb.Mods.file.add_observer = function(fn) end

        -- read_content_to_table("mods.lst") -> the staged order (or false).
        sb.Mods.file.read_content_to_table = function(path)
            runner.assert_eq("mods.lst", path, "order read must target 'mods.lst'")
            if opts.missing_order then return false end
            return opts.order or { "alpha", "beta" }
        end

        -- exec_with_return(name .. "/" .. name .. ".mod") -> the .mod table.
        sb.Mods.file.exec_with_return = function(path)
            if opts.mod_files then return opts.mod_files[path] end
            return nil
        end

        return sb, registry
    end

    local function load_driver(sb)
        return mock.run_module("mod_manager", sb)
    end

    local function new_loaded(sb)
        local ModManager = load_driver(sb)
        local mm = ModManager:new()
        mm:update(0.016)
        return mm
    end

    -- A recording mod object.
    local function recording_mod(name, seq, fail_phase)
        return {
            init = function(self)
                table.insert(seq, name .. ":init")
                if fail_phase == "init" then error(name .. " init boom") end
            end,
            update = function(self, dt) end,
            on_game_state_changed = function(self, status, sname) end,
        }
    end

    -- .mod builder.
    local function mod_file(name, object, seq, fail_run)
        return {
            run = function()
                if seq then table.insert(seq, name .. ":run") end
                if fail_run then error(name .. " run boom") end
                return object
            end,
        }
    end

    -- path key helper matching the loader's .mod path.
    local function mod_path(name)
        return name .. "/" .. name .. ".mod"
    end

    -- ---------------------------------------------------------------------
    -- Class declaration
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: declares ModManager via class()", function()
        local sb, reg = setup()
        local ModManager = load_driver(sb)
        runner.assert_type("table", ModManager)
        runner.assert_eq("ModManager", reg.ModManager.name)
    end)

    runner.register("mod_manager: defines init/update/on_game_state_changed/destroy", function()
        local sb = setup()
        local ModManager = load_driver(sb)
        runner.assert_type("function", ModManager.init)
        runner.assert_type("function", ModManager.update)
        runner.assert_type("function", ModManager.on_game_state_changed)
        runner.assert_type("function", ModManager.destroy)
    end)

    -- ---------------------------------------------------------------------
    -- SCAN phase (init)
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: init() scans only — builds _mods, loads no mod", function()
        local sb = setup({ order = { "usermod" } })
        local load_calls = {}
        sb.Mods.file.exec_with_return = function(p) table.insert(load_calls, p); return nil end
        local ModManager = load_driver(sb)
        local mm = ModManager:new()

        runner.assert_eq({}, load_calls, "init must NOT exec .mod files (scan only)")
        runner.assert_nil(mm._state, "_state must NOT be set by init")
        runner.assert_eq(false, mm._mods_loaded, "_mods_loaded false after init")
        runner.assert_eq(1, #mm._mods, "exactly the listed mods scanned")
        runner.assert_eq(1, mm._mods[1].id)
        runner.assert_eq("usermod", mm._mods[1].name)
        runner.assert_eq("usermod", mm._mods[1].handle)
        runner.assert_eq("not_loaded", mm._mods[1].state)
        runner.assert_nil(mm._mods[1].object)
        runner.assert_eq(false, mm._settings.developer_mode, "developer_mode defaults false")
    end)

    runner.register("mod_manager: init() assigns Managers.mod = self", function()
        local sb = setup({ order = {} })
        local ModManager = load_driver(sb)
        local mm = ModManager:new()
        runner.assert_eq(mm, sb.Managers.mod, "init must set Managers.mod")
    end)

    runner.register("mod_manager: missing mods.lst -> empty _mods, no crash", function()
        local sb = setup({ missing_order = true })
        local ModManager = load_driver(sb)
        local mm = ModManager:new()
        runner.assert_eq(0, #mm._mods)
        mm:update(0.016)
        runner.assert_eq("done", mm._state, "still reaches done with empty list")
    end)

    runner.register("mod_manager: missing mods.lst logs a clear [mod_loader] message", function()
        local logged = {}
        local sb = setup({ missing_order = true })
        sb.__print = function(m) table.insert(logged, m) end
        load_driver(sb):new()
        local found = false
        for _, line in ipairs(logged) do
            if line:find("mods%.lst") and line:find("missing") then
                found = true
                break
            end
        end
        runner.assert_eq(true, found,
            "missing mods.lst must log a clear message naming mods.lst as missing")
    end)

    runner.register("mod_manager: empty mods.lst -> empty _mods, no crash", function()
        local sb = setup({ order = {} })
        local ModManager = load_driver(sb)
        local mm = ModManager:new()
        runner.assert_eq(0, #mm._mods)
        mm:update(0.016)
        runner.assert_eq("done", mm._state)
    end)

    -- ---------------------------------------------------------------------
    -- LOAD phase (first update)
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: _state nil after init, 'done' after first update (once)", function()
        local state_done_during_load = false
        local sb = setup({ order = { "dmf" } })
        sb.Mods.file.exec_with_return = function(p)
            return mod_file("dmf", {
                init = function() state_done_during_load = (sb.Managers.mod._state == "done") end,
            })
        end
        local mm = load_driver(sb):new()
        runner.assert_nil(mm._state)
        mm:update(0.016)
        runner.assert_eq(false, state_done_during_load,
            "_state must NOT be 'done' while the load loop is running")
        runner.assert_eq("done", mm._state)
        -- A second update must not change _state.
        mm:update(0.033)
        runner.assert_eq("done", mm._state)
    end)

    runner.register("mod_manager: loads exactly the listed mods in order (no injection)", function()
        local sb = setup({ order = { "dmf", "usermod" } })
        local loaded = {}
        local dobj, uobj = { init = function() end }, { init = function() end }
        sb.Mods.file.exec_with_return = function(p)
            table.insert(loaded, p)
            return ({ [mod_path("dmf")] = mod_file("dmf", dobj),
                      [mod_path("usermod")] = mod_file("usermod", uobj) })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq({ mod_path("dmf"), mod_path("usermod") }, loaded)
        runner.assert_eq(2, #mm._mods)
        runner.assert_eq(dobj, mm._mods[1].object)
        runner.assert_eq(uobj, mm._mods[2].object)
    end)

    runner.register("mod_manager: run() then init() per mod, before the next mod loads", function()
        local seq = {}
        local sb = setup({ order = { "alpha", "beta" } })
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("alpha")] = mod_file("alpha", recording_mod("alpha", seq), seq),
                      [mod_path("beta")] = mod_file("beta", recording_mod("beta", seq), seq) })[p]
        end
        new_loaded(sb)
        runner.assert_eq({ "alpha:run", "alpha:init", "beta:run", "beta:init" }, seq)
    end)

    runner.register("mod_manager: run() failure is skipped (logged), load continues to done", function()
        local logged = {}
        local sb = setup({ order = { "boom", "good" } })
        sb.__print = function(m) table.insert(logged, m) end
        local good_init = 0
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("boom")] = mod_file("boom", nil, nil, true),
                      [mod_path("good")] = mod_file("good", { init = function() good_init = good_init + 1 end }) })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq("done", mm._state)
        runner.assert_eq(2, #mm._mods)
        runner.assert_nil(mm._mods[1].object, "boom's run failed -> no object")
        runner.assert_truthy(mm._mods[2].object ~= nil, "good still loads")
        runner.assert_eq(1, good_init)
        runner.assert_truthy(logged[1]:find("mod 'boom' run failed") ~= nil)
    end)

    runner.register("mod_manager: run() returning nil is DMF-driven (not failure, not outer-driven)", function()
        local logged = {}
        local sb = setup({ order = { "dmfmod", "later" } })
        sb.__print = function(m) table.insert(logged, m) end
        local handle_seen
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("dmfmod")] = {
                    run = function()
                        local m = sb.Managers.mod
                        local entry = m._mods[m._mod_load_index]
                        handle_seen = entry and entry.handle
                        -- DMF convention: side-effect registration, no return.
                    end,
                },
                [mod_path("later")] = mod_file("later", { init = function() end }),
            })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq("done", mm._state)
        runner.assert_eq("dmfmod", handle_seen,
            "_mods[_mod_load_index].handle resolves during the nil-return mod's run")
        runner.assert_nil(mm._mods[1].object, "DMF-driven mod has no outer object")
        runner.assert_eq("dmf_driven", mm._mods[1].state)
        runner.assert_truthy(mm._mods[2].object ~= nil, "later still loads")
        -- DMF-driven log is benign, not "skipped"/"failed".
        local dmlog
        for _, line in ipairs(logged) do
            if line:find("mod 'dmfmod'") then dmlog = line; break end
        end
        runner.assert_not_nil(dmlog)
        runner.assert_truthy(dmlog:find("DMF%-driven") ~= nil)
    end)

    runner.register("mod_manager: init() failure -> object not driven", function()
        local logged = {}
        local sb = setup({ order = { "boom", "good" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("boom")] = mod_file("boom", recording_mod("boom", {}, "init")),
                [mod_path("good")] = mod_file("good", { init = function() end }),
            })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq("done", mm._state)
        runner.assert_nil(mm._mods[1].object, "failed-init object must not be driven")
        runner.assert_truthy(mm._mods[2].object ~= nil, "good still loads")
        runner.assert_truthy(logged[1]:find("mod 'boom' init failed") ~= nil)
        -- Driving update must not touch the failed-init mod's object.
        local droven = false
        -- (object is nil, so the update loop skips it by construction)
        mm:update(0.033)
        runner.assert_nil(mm._mods[1].object)
    end)

    runner.register("mod_manager: missing .mod file logged + skipped, load continues", function()
        local logged = {}
        local sb = setup({ order = { "ghost", "real" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            if p == mod_path("ghost") then return false end  -- missing
            return ({ [mod_path("real")] = mod_file("real", { init = function() end }) })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq("done", mm._state)
        runner.assert_nil(mm._mods[1].object)
        runner.assert_truthy(mm._mods[2].object ~= nil)
        runner.assert_truthy(logged[1]:find("mod 'ghost'") ~= nil)
    end)

    runner.register("mod_manager: .mod without run() logged + skipped", function()
        local logged = {}
        local sb = setup({ order = { "bad" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("bad")] = { no_run = true } })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq("done", mm._state)
        runner.assert_nil(mm._mods[1].object)
        runner.assert_truthy(logged[1]:find("mod 'bad'") ~= nil)
    end)

    runner.register("mod_manager: invalid DMF entry shape is skipped at the load boundary; load continues", function()
        -- The DMF-required entry shape is validated at the load boundary
        -- (adapter:validate_entry). Scan always produces well-formed entries,
        -- so to exercise the failure branch we mutate a scanned entry into an
        -- invalid shape between init() and update() and confirm: the invalid
        -- entry is skipped with the clear "mod entry invalid (...)" log, its
        -- .mod is never executed, the later valid entry still loads, the pass
        -- reaches _state == "done", and _mod_load_index clears.
        local logged = {}
        local sb = setup({ order = { "badshape", "good" } })
        sb.__print = function(m) table.insert(logged, m) end
        local exec_paths = {}
        sb.Mods.file.exec_with_return = function(p)
            table.insert(exec_paths, p)
            return ({ [mod_path("good")] = mod_file("good", { init = function() end }) })[p]
        end
        local ModManager = load_driver(sb)
        local mm = ModManager:new()  -- SCAN: both entries well-formed
        -- Mutate the first entry into a shape the adapter rejects (no handle).
        -- The "good" entry is left intact so it should still load.
        mm._mods[1].handle = nil
        mm:update(0.016)

        -- The invalid entry is skipped with the clear log line.
        local invalid_log
        for _, line in ipairs(logged) do
            if line:find("mod entry invalid") then invalid_log = line; break end
        end
        runner.assert_not_nil(invalid_log, "expected a 'mod entry invalid (...)' log line")
        -- The invalid entry's .mod was never executed.
        local bad_executed = false
        for _, p in ipairs(exec_paths) do
            if p == mod_path("badshape") then bad_executed = true; break end
        end
        runner.assert_eq(false, bad_executed,
            "the invalid entry's .mod must not be executed")
        -- The later valid entry still loads.
        runner.assert_truthy(mm._mods[2].object ~= nil,
            "the valid entry after the invalid one must still load")
        runner.assert_eq("running", mm._mods[2].state)
        -- The invalid entry's object is untouched (no load attempted).
        runner.assert_nil(mm._mods[1].object)
        runner.assert_eq("not_loaded", mm._mods[1].state)
        -- The pass completes and the DMF contract fields settle.
        runner.assert_eq("done", mm._state)
        runner.assert_nil(mm._mod_load_index,
            "_mod_load_index must clear after the load loop completes")
    end)

    runner.register("mod_manager: _mod_load_index cleared after load", function()
        local sb = setup({ order = { "dmf" } })
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("dmf")] = mod_file("dmf", { init = function() end }) })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_nil(sb.Managers.mod._mod_load_index,
            "_mod_load_index cleared after the load loop completes")
    end)

    -- ---------------------------------------------------------------------
    -- Per-frame drive
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: update(dt) fans out to each loaded mod's update", function()
        local calls = {}
        local sb = setup({ order = { "dmf" } })
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("dmf")] = mod_file("dmf",
                { update = function(self, dt) table.insert(calls, dt) end }) })[p]
        end
        local mm = load_driver(sb):new()
        mm:update(0.016)
        runner.assert_eq({ 0.016 }, calls)
        mm:update(0.033)
        runner.assert_eq({ 0.016, 0.033 }, calls)
    end)

    runner.register("mod_manager: update() failure isolated (one mod's error doesn't block others)", function()
        local logged = {}
        local sb = setup({ order = { "boom", "good" } })
        sb.__print = function(m) table.insert(logged, m) end
        local good_dt
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("boom")] = mod_file("boom", {
                    init = function() end, update = function() error("u boom") end,
                }),
                [mod_path("good")] = mod_file("good", {
                    init = function() end, update = function(self, dt) good_dt = dt end,
                }),
            })[p]
        end
        new_loaded(sb)
        runner.assert_eq(0.016, good_dt)
        runner.assert_truthy(logged[1]:find("mod 'boom' update failed") ~= nil)
    end)

    runner.register("mod_manager: update skips mods without update() (no error)", function()
        local logged = {}
        local sb = setup({ order = { "dmf" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("dmf")] = mod_file("dmf", { init = function() end }) })[p]
        end
        local mm = load_driver(sb):new()
        local ok, err = pcall(function() mm:update(0.016) end)
        runner.assert_eq(true, ok, tostring(err))
        runner.assert_eq(0, #logged)
    end)

    runner.register("mod_manager: on_game_state_changed forwards status+name+object; isolated", function()
        local logged = {}
        local sb = setup({ order = { "boom", "good" } })
        sb.__print = function(m) table.insert(logged, m) end
        local good_recv
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("boom")] = mod_file("boom", {
                    init = function() end,
                    on_game_state_changed = function() error("gsc boom") end,
                }),
                [mod_path("good")] = mod_file("good", {
                    init = function() end,
                    on_game_state_changed = function(self, status, name, obj)
                        good_recv = { status, name, obj }
                    end,
                }),
            })[p]
        end
        local mm = new_loaded(sb)
        local sobj = { _name = "StateIngame" }
        mm:on_game_state_changed("enter", "StateIngame", sobj)
        runner.assert_eq({ "enter", "StateIngame", sobj }, good_recv)
        runner.assert_truthy(logged[1]:find("mod 'boom' on_game_state_changed failed") ~= nil)
    end)

    runner.register("mod_manager: destroy() calls on_unload in reverse order; isolated", function()
        local unloaded = {}
        local logged = {}
        local sb = setup({ order = { "dmf", "alpha", "beta" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("dmf")] = mod_file("dmf", {
                    init = function() end, on_unload = function() table.insert(unloaded, "dmf") end,
                }),
                [mod_path("alpha")] = mod_file("alpha", {
                    init = function() end, on_unload = function() table.insert(unloaded, "alpha") end,
                }),
                [mod_path("beta")] = mod_file("beta", {
                    init = function() end, on_unload = function() error("unload boom") end,
                }),
            })[p]
        end
        local mm = new_loaded(sb)
        mm:destroy()
        runner.assert_eq({ "alpha", "dmf" }, unloaded,
            "destroy() must call on_unload in reverse load order (beta failed)")
        runner.assert_truthy(logged[1]:find("mod 'beta' on_unload failed") ~= nil)
    end)

    runner.register("mod_manager: destroy() skips mods without on_unload", function()
        local logged = {}
        local sb = setup({ order = { "dmf", "noul" } })
        sb.__print = function(m) table.insert(logged, m) end
        local unloaded = false
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("dmf")] = mod_file("dmf", {
                    init = function() end, on_unload = function() unloaded = true end,
                }),
                [mod_path("noul")] = mod_file("noul", { init = function() end }),
            })[p]
        end
        local mm = new_loaded(sb)
        local ok, err = pcall(function() mm:destroy() end)
        runner.assert_eq(true, ok, tostring(err))
        runner.assert_eq(0, #logged)
        runner.assert_eq(true, unloaded)
    end)

    -- ---------------------------------------------------------------------
    -- Real cross-module integration: real file.lua + real mod_manager.lua +
    -- real dmf_adapter.lua. (The DMF IO unit coverage — exact safe/unsafe
    -- routing, path construction, debug/error logging, installation-aware
    -- re-adaptation — lives in test_dmf_adapter.lua. This test stays here to
    -- prove the adapter is USED through real file + manager integration.)
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: real file+manager+adapter observer integration — adapts on DMFMod surface", function()
        -- Load the REAL file.lua + REAL mod_manager.lua (which itself loads the
        -- REAL dmf_adapter.lua via Mods.load_module) in one sandbox. The
        -- observer the adapter registers is the real file.lua observer.
        -- Execute a real staged chunk through Mods.file.dofile that surfaces a
        -- DMFMod io surface; verify the real observer adapts before any
        -- Phase-2 call uses the method, and that the adapter diagnostic
        -- reflects the new generation.
        local sb = mock.new_sandbox()
        -- fake class so mod_manager.lua can call class("ModManager")
        local registry = {}
        sb.class = function(name)
            local meta = { name = name }
            meta.__index = meta
            meta.new = function(self, ...)
                local inst = setmetatable({}, meta)
                if meta.init then meta.init(inst, ...) end
                return inst
            end
            registry[name] = meta
            return meta
        end
        sb.__print = function() end
        sb.Managers = {}
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }
        -- mod_manager.lua loads dmf_adapter.lua via Mods.load_module; wire it
        -- to the mock's source loader so the real adapter source runs in the
        -- sandbox.
        sb.Mods.load_module = function(name)
            return mock.run_module(name, sb)
        end

        local files = {}
        -- A synthetic chunk that, when executed, surfaces DMFMod with its io_*
        -- methods (mirrors what DMF's core/io.lua does, without copying DMF).
        files[mock.MOD_ROOT .. "/dmf/core/io.lua"] = table.concat({
            "DMFMod = {}",
            "function DMFMod:io_dofile(p) return 'WRONG:' .. p end",
            "function DMFMod:io_dofile_unsafe(p) error('WRONG_UNSAFE:' .. p) end",
        }, "\n")
        files[mock.MOD_ROOT .. "/mods.lst"] = ""
        -- A real lua chunk the adapted io_dofile will delegate to.
        files[mock.MOD_ROOT .. "/delegated.lua"] = "return 'delegated-value'"

        sb.Mods.lua.io = mock.make_io(files)
        sb.Mods.lua.loadstring = sb.loadstring

        -- Load real file.lua, then real mod_manager.lua (shares the sandbox).
        -- mod_manager.lua's module top loads dmf_adapter.lua via the wired
        -- Mods.load_module, so the real adapter factory is in scope when the
        -- manager instance constructs.
        mock.run_module("file", sb)
        mock.run_module("mod_manager", sb)

        local mm = registry.ModManager:new()  -- init: registers the real observer
        runner.assert_nil(mm._adapter:adapted_dmfmod(), "not yet adapted")

        -- Execute the chunk that surfaces DMFMod.io_* through real Mods.file.
        -- file.lua notifies the real observer after the successful exec, which
        -- triggers adaptation BEFORE any Phase-2 call uses the method.
        sb.Mods.file.dofile("dmf/core/io")
        runner.assert_eq(sb.DMFMod, mm._adapter:adapted_dmfmod(),
            "real observer fired + adapted after the DMFMod-surfacing exec")

        -- io_dofile now delegates to real file.dofile (mod-root), not the
        -- original WRONG method the chunk installed.
        local inst = setmetatable({}, { __index = sb.DMFMod })
        runner.assert_eq("delegated-value", inst:io_dofile("delegated"),
            "io_dofile delegates to real file.dofile (mod-root), not the WRONG original")

        -- io_dofile_unsafe delegates to real file.dofile_unsafe (which raises
        -- on a runtime error in the delegated chunk); the WRONG method is NOT
        -- called. Stage a chunk that raises to confirm the unsafe routing.
        files[mock.MOD_ROOT .. "/throws.lua"] = "error('chunk-throws')"
        local ok, err = pcall(function() inst:io_dofile_unsafe("throws") end)
        runner.assert_eq(false, ok, "io_dofile_unsafe delegates to the real unsafe op (which raises)")
        runner.assert_truthy(tostring(err):find("chunk%-throws") ~= nil,
            "the delegated chunk's error surfaces (not DMFMod's WRONG_UNSAFE)")
    end)

    -- ---------------------------------------------------------------------
    -- Managers.mod shape contract (DMF reads _mods[_mod_load_index])
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: _mods[_mod_load_index].handle resolves per mod", function()
        local seen = {}
        local sb = setup({ order = { "dmf", "usermod" } })
        local function reading_obj(tag)
            return {
                init = function()
                    local m = sb.Managers.mod
                    local entry = m._mods[m._mod_load_index]
                    seen[tag] = entry and entry.handle or nil
                end,
            }
        end
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("dmf")] = { run = function() return reading_obj("dmf") end },
                [mod_path("usermod")] = { run = function() return reading_obj("usermod") end },
            })[p]
        end
        new_loaded(sb)
        runner.assert_eq("dmf", seen.dmf, "index 1 reads its own handle during init")
        runner.assert_eq("usermod", seen.usermod, "index 2 reads its own handle during init")
    end)

    runner.register("mod_manager: _mods entries expose id/name/handle", function()
        local sb = setup({ order = { "alpha", "beta" } })
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("alpha")] = mod_file("alpha", { init = function() end }),
                [mod_path("beta")] = mod_file("beta", { init = function() end }),
            })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq(1, mm._mods[1].id)
        runner.assert_eq("alpha", mm._mods[1].name)
        runner.assert_eq("alpha", mm._mods[1].handle)
        runner.assert_eq(2, mm._mods[2].id)
        runner.assert_eq("beta", mm._mods[2].name)
        runner.assert_eq("beta", mm._mods[2].handle)
    end)
end
