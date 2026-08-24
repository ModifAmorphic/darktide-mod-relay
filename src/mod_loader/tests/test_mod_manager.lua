-- test_mod_manager.lua — the loader driver (src/mod_loader/mod_manager.lua).
--
-- Asserts the external behavior contract:
--   - declares class("ModManager") (so CLASS.ModManager.destroy exists for DMF)
--   - generic scan/load/lifecycle: init() scans mods.lst into _mods (id/name/
--     handle, no load); update(dt) loads on first call (per-mod run/init in
--     order), then drives update + on_game_state_changed; destroy() calls
--     on_unload in reverse. run/init failures are isolated (skipped/logged,
--     load continues); a nil run() result is DMF-driven success, not
--     outer-driven.
--   - the DMF-visible contract fields (_state, _mod_load_index, _settings) are
--     driven through the dmf_adapter; mod_manager itself never writes them
--     directly. The DMF IO adaptation (eight DMFMod:io_* overrides, path
--     construction, debug/error logging, observer timing, installation-aware
--     re-adaptation) is covered in test_dmf_adapter.lua.

local mock = require("mock")

return function(runner)
    -- Build a sandbox with the fakes mod_manager needs: `class` (so it can call
    -- class("ModManager")), Mods.file (read_content_to_table + exec_with_return),
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

        sb.Mods = { file = {}, _relay = { version = "0.2.0" } }
        -- mod_manager reads leveled diagnostics from Mods._relay.log_<level>
        -- (the helper init.lua publishes in production). This isolated test does
        -- not run init, so attach the test fake before loading the module.
        mock.attach_logger(sb)
        sb.Crashify = {
            print_property = function() end,
            remove_print_property = function() end,
        }

        -- The chassis (lifecycle.lua module scope) loads dmf_adapter exactly
        -- once per process and publishes it on Mods._relay.dmf_adapter;
        -- mod_manager's init reads it from there. Simulate that chassis load
        -- here (the real wiring is covered by test_lifecycle).
        sb.Mods._relay.dmf_adapter = mock.run_module("dmf_adapter", sb)

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

    -- Create the manager the way production does: :new() (init constructs the
    -- built-in's own adapter instance) followed by the chassis Step-1c built-in
    -- path — the manager's own adapter establishes (Managers.mod publication +
    -- settings restore-if-nil) and registers the io observer (a no-op stub in
    -- this isolated setup). The real chassis wiring is covered by test_lifecycle.
    local function new_manager(sb)
        local mm = load_driver(sb):new()
        mm._adapter:establish()
        mm._adapter:register_io_observer()
        return mm
    end

    -- Tick update(0.016) until the load pass finalizes (phased loading: the
    -- phase-0 anchor tick loads nothing, then one entry per tick). Bounded;
    -- asserts the pass actually completes. Returns the ticks driven.
    local function tick_to_done(mm, bound)
        bound = bound or 100
        local ticks = 0
        while not mm._adapter:is_load_done() do
            ticks = ticks + 1
            if ticks > bound then
                runner.fail("load pass did not finalize within " .. bound .. " ticks")
            end
            mm:update(0.016)
        end
        return ticks
    end

    local function new_loaded(sb)
        local mm = new_manager(sb)
        tick_to_done(mm)
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

    -- Find the first log line containing a substring (plain find); nil if absent.
    local function find_log(logged, sub)
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find(sub, 1, true) then return line end
        end
        return nil
    end

    -- Count log lines containing a substring (plain find).
    local function count_log(logged, sub)
        local n = 0
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find(sub, 1, true) then n = n + 1 end
        end
        return n
    end

    -- Count WARN/ERROR-level lines. A load pass emits low-volume DEBUG lines by
    -- contract (scan summary, pass summary), so "no error" assertions must
    -- filter by level rather than count all lines.
    local function count_error_level(logged)
        local n = 0
        for _, line in ipairs(logged) do
            if type(line) == "string"
               and (line:find("^ERROR ", 1, false) or line:find("^WARN ", 1, false)) then
                n = n + 1
            end
        end
        return n
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
        local mm = new_manager(sb)

        runner.assert_eq({}, load_calls, "init must NOT exec .mod files (scan only)")
        runner.assert_nil(mm._state, "_state must NOT be set by init")
        runner.assert_eq(false, mm._mods_loaded, "_mods_loaded false after init")
        runner.assert_eq(1, #mm._mods, "exactly the listed mods scanned")
        runner.assert_eq(1, mm._mods[1].id)
        runner.assert_eq("usermod", mm._mods[1].name)
        runner.assert_eq("usermod", mm._mods[1].handle)
        runner.assert_eq("not_loaded", mm._mods[1].state)
        runner.assert_nil(mm._mods[1].object)
        runner.assert_eq(false, mm._settings.developer_mode,
            "developer_mode defaults false via chassis establish")
    end)

    runner.register("mod_manager: init does NOT publish; the chassis establish publishes Managers.mod", function()
        -- New structure: init constructs the built-in's own adapter but never
        -- publishes (establish/observer are chassis Step-1c duties). Managers.mod
        -- publication + settings restore happen through the adapter's establish,
        -- which the chassis calls right after creation.
        local sb = setup({ order = {} })
        local mm = load_driver(sb):new()
        runner.assert_nil(sb.Managers.mod,
            "init alone must not publish Managers.mod (chassis owns publication)")
        mm._adapter:establish()
        runner.assert_eq(mm, sb.Managers.mod,
            "the chassis establish publishes the manager at Managers.mod")
    end)

    runner.register("mod_manager: missing mods.lst -> empty _mods, no crash", function()
        local sb = setup({ missing_order = true })
        local mm = new_manager(sb)
        runner.assert_eq(0, #mm._mods)
        mm:update(0.016)
        runner.assert_eq("done", mm._state, "still reaches done with empty list")
    end)

    runner.register("mod_manager: missing mods.lst logs a clear [mod_loader] message", function()
        local logged = {}
        local sb = setup({ missing_order = true })
        sb.__print = function(m) table.insert(logged, m) end
        new_manager(sb)
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

    runner.register("mod_manager: diagnostic lines carry the {LEVEL} [mod_loader] prefix (community format)", function()
        -- A migrated call site end-to-end: the missing-mods.lst path logs at
        -- WARN, so its line must carry the full community prefix. Confirms a
        -- real mod_manager path routes through the leveled helper.
        local logged = {}
        local sb = setup({ missing_order = true })
        sb.__print = function(m) table.insert(logged, m) end
        new_manager(sb)
        local leveled = nil
        for _, line in ipairs(logged) do
            if line:find("^WARN %[mod_loader%] ", 1) then
                leveled = line
                break
            end
        end
        runner.assert_not_nil(leveled, "expected a 'WARN [mod_loader] ...' line")
        runner.assert_truthy(leveled:find("mods%.lst missing") ~= nil,
            "the leveled line carries the message body")
    end)

    runner.register("mod_manager: empty mods.lst -> empty _mods, no crash", function()
        local sb = setup({ order = {} })
        local mm = new_manager(sb)
        runner.assert_eq(0, #mm._mods)
        mm:update(0.016)
        runner.assert_eq("done", mm._state)
    end)

    -- ---------------------------------------------------------------------
    -- LOAD phase (first update)
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: _state nil after init, 'done' once the pass finalizes", function()
        local state_done_during_load = false
        local sb = setup({ order = { "dmf" } })
        sb.Mods.file.exec_with_return = function(p)
            return mod_file("dmf", {
                init = function() state_done_during_load = (sb.Managers.mod._state == "done") end,
            })
        end
        local mm = new_manager(sb)
        runner.assert_nil(mm._state)
        tick_to_done(mm)
        runner.assert_eq(false, state_done_during_load,
            "_state must NOT be 'done' while the entry is loading")
        runner.assert_eq("done", mm._state)
        -- A later tick must not change _state.
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
        runner.assert_not_nil(find_log(logged, "mod 'boom' run failed"))
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
        runner.assert_not_nil(find_log(logged, "mod 'boom' init failed"))
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
        runner.assert_not_nil(find_log(logged, "mod 'ghost'"))
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
        runner.assert_not_nil(find_log(logged, "mod 'bad'"))
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
        local mm = new_manager(sb)  -- SCAN: both entries well-formed
        -- Mutate the first entry into a shape the adapter rejects (no handle).
        -- The "good" entry is left intact so it should still load.
        mm._mods[1].handle = nil
        tick_to_done(mm)

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
        runner.assert_eq("failed", mm._mods[1].state)
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
    -- Phased loading: phase-0 anchor tick + exactly ONE entry per manager
    -- tick, in mods.lst order (community loader parity).
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: phased — first update is the phase-0 anchor, loads NO entries", function()
        local sb = setup({ order = { "alpha", "beta" } })
        local execd = {}
        sb.Mods.file.exec_with_return = function(p)
            table.insert(execd, p)
            return ({ [mod_path("alpha")] = mod_file("alpha", { init = function() end }),
                      [mod_path("beta")] = mod_file("beta", { init = function() end }) })[p]
        end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor tick: pass bookkeeping only
        runner.assert_eq({}, execd, "the anchor tick executes no .mod")
        runner.assert_eq("not_loaded", mm._mods[1].state)
        runner.assert_eq("not_loaded", mm._mods[2].state)
        runner.assert_eq(false, mm._adapter:is_load_done(), "the pass is still in flight")
        runner.assert_nil(mm._mod_load_index, "no begin_load_entry fired on the anchor")
    end)

    runner.register("mod_manager: phased — entry i loads exactly on tick i+1, in list order", function()
        local logged = {}
        local sb = setup({ order = { "alpha", "beta" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods._relay._trace_enabled = true
        local load_tick = {}
        local ticks = 0
        sb.Mods.file.exec_with_return = function(p)
            load_tick[p:match("^(.-)/")] = ticks  -- the tick currently running
            return ({ [mod_path("alpha")] = mod_file("alpha", { init = function() end }),
                      [mod_path("beta")] = mod_file("beta", { init = function() end }) })[p]
        end
        local mm = new_manager(sb)
        while not mm._adapter:is_load_done() do
            ticks = ticks + 1
            mm:update(0.016)
            if ticks == 1 then
                runner.assert_nil(load_tick.alpha, "nothing loads on the anchor tick")
                runner.assert_eq(0, count_log(logged, "load pass end"),
                    "no pass-end line before the finalize tick")
            elseif ticks == 2 then
                runner.assert_eq(2, load_tick.alpha, "alpha loads on tick 2 (phase 1)")
                runner.assert_nil(load_tick.beta, "beta still unloaded after tick 2")
                runner.assert_eq(false, mm._adapter:is_load_done(), "pass active after tick 2")
                runner.assert_eq(0, count_log(logged, "load pass end"),
                    "no pass-end line before the finalize tick")
            end
        end
        runner.assert_eq(3, ticks, "the 2-entry pass finalizes on tick 3")
        runner.assert_eq(3, load_tick.beta, "beta loads on tick 3 (phase 2)")
        runner.assert_eq(true, mm._adapter:is_load_done())
        runner.assert_eq("running", mm._mods[1].state)
        runner.assert_eq("running", mm._mods[2].state)
        runner.assert_eq(1, count_log(logged, "load pass end (initial, generation 1)"),
            "the pass-end TRACE lands exactly once, on the initial finalize tick")
    end)

    runner.register("mod_manager: phased — updates interleave: first update on the entry's own load tick", function()
        -- Earlier entries keep receiving updates while later entries are
        -- still unloaded; each entry's FIRST update fires on its own load
        -- tick (load step, then the same tick's update fan-out).
        local events = {}
        local sb = setup({ order = { "alpha", "beta" } })
        local function outer(name)
            return {
                init = function() table.insert(events, name .. ":init") end,
                update = function() table.insert(events, name .. ":update") end,
            }
        end
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("alpha")] = mod_file("alpha", outer("alpha")),
                      [mod_path("beta")] = mod_file("beta", outer("beta")) })[p]
        end
        local mm = new_manager(sb)
        tick_to_done(mm)
        -- tick 2: alpha:init then alpha:update. tick 3: beta:init, then the
        -- fan-out drives alpha (already loaded) and beta (just loaded).
        runner.assert_eq({
            "alpha:init", "alpha:update",
            "beta:init", "alpha:update", "beta:update",
        }, events)
    end)

    runner.register("mod_manager: phased — a failing entry burns its phase; the next entry loads one tick later", function()
        local sb = setup({ order = { "boom", "good" } })
        local load_tick = {}
        local ticks = 0
        sb.Mods.file.exec_with_return = function(p)
            load_tick[p:match("^(.-)/")] = ticks
            return ({ [mod_path("boom")] = mod_file("boom", nil, nil, true),
                      [mod_path("good")] = mod_file("good", { init = function() end }) })[p]
        end
        local mm = new_manager(sb)
        while not mm._adapter:is_load_done() do
            ticks = ticks + 1
            mm:update(0.016)
            if ticks == 1 then
                runner.assert_nil(next(load_tick), "nothing loads on the anchor tick")
            end
        end
        runner.assert_eq(3, ticks, "boom burned phase 1; good waited for its own tick")
        runner.assert_eq(2, load_tick.boom, "boom's failed run still consumed tick 2")
        runner.assert_eq(3, load_tick.good, "good loads on tick 3, not early on tick 2")
        runner.assert_eq("failed", mm._mods[1].state)
        runner.assert_eq("running", mm._mods[2].state)
        runner.assert_eq(true, mm._adapter:is_load_done())
    end)

    runner.register("mod_manager: phased — framework init failure finalizes on THAT tick; later entries skipped", function()
        local logged = {}
        local seq = {}
        local sb = setup({ order = { "prior", "dmf", "later" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods._relay._trace_enabled = true
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("prior")] = mod_file("prior", {
                    init = function() table.insert(seq, "prior:init") end,
                    on_unload = function() table.insert(seq, "prior:unload") end,
                }),
                [mod_path("dmf")] = mod_file("dmf", {
                    init = function() table.insert(seq, "dmf:init"); error("framework escape") end,
                    on_unload = function() table.insert(seq, "dmf:unload") end,
                }),
                [mod_path("later")] = mod_file("later", { init = function() end }),
            })[p]
        end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor
        runner.assert_eq("not_loaded", mm._mods[3].state)
        mm:update(0.016)  -- prior loads
        runner.assert_eq(false, mm._adapter:is_load_done(), "pass active after prior's tick")
        mm:update(0.016)  -- dmf's init raises -> finalize on THIS tick
        runner.assert_eq(true, mm._adapter:is_load_done(),
            "the pass finalizes on the framework-failure tick")
        runner.assert_eq({ "prior:init", "dmf:init", "dmf:unload", "prior:unload" }, seq,
            "reverse-order cleanup ran on the failure tick")
        runner.assert_eq("stopped", mm._mods[1].state)
        runner.assert_eq("disabled", mm._mods[2].state)
        runner.assert_eq("skipped", mm._mods[3].state, "later never loaded -> skipped")
        runner.assert_eq(true, mm._generation_failed)
        runner.assert_eq(1, count_log(logged, "entry 'later' result=skipped"),
            "the skipped collateral reports exactly once")
        runner.assert_eq(1, count_log(logged, "initial load pass complete: 3 entries, 1 failed"),
            "the summary counts the framework failure")
        runner.assert_nil(mm._mod_load_index)
    end)

    runner.register("mod_manager: phased — empty mods.lst begins AND finalizes on the anchor tick", function()
        local logged = {}
        local sb = setup({ order = {} })
        sb.__print = function(m) table.insert(logged, m) end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor == finalize
        runner.assert_eq(true, mm._adapter:is_load_done(), "empty pass done on the anchor tick")
        runner.assert_eq(1, mm._generation)
        runner.assert_eq(1, count_log(logged, "initial load pass complete: 0 entries, 0 failed"))

        -- A missing mods.lst behaves the same (0 entries; scan already WARNed).
        local sb2 = setup({ missing_order = true })
        local mm2 = new_manager(sb2)
        mm2:update(0.016)
        runner.assert_eq(true, mm2._adapter:is_load_done(),
            "missing-list pass also begins and finalizes on the anchor tick")
    end)

    runner.register("mod_manager: phased — escaped load-step error force-finalizes; remaining entries stay not_loaded", function()
        -- A raising Mods.file.exec_with_return escapes _load_one (no inner
        -- pcall on that call, by design — the pass-level containment owns it).
        local logged = {}
        local sb = setup({ order = { "alpha", "beta" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            if p == mod_path("alpha") then error("exec transport boom") end
            return mod_file("beta", { init = function() end })
        end
        local mm = new_manager(sb)
        local ticks = 0
        while not mm._adapter:is_load_done() do
            ticks = ticks + 1
            mm:update(0.016)
        end
        runner.assert_eq(2, ticks, "the escape finalizes on the entry's tick")
        runner.assert_eq(true, mm._adapter:is_load_done())
        runner.assert_eq("not_loaded", mm._mods[1].state, "the escaping entry stays not_loaded")
        runner.assert_eq("not_loaded", mm._mods[2].state, "remaining entries stay not_loaded")
        runner.assert_nil(mm._mod_load_index)
        runner.assert_not_nil(find_log(logged, "initial mod load pass error:"))
        runner.assert_not_nil(find_log(logged, "exec transport boom"),
            "the escaped error text is logged")
        runner.assert_not_nil(find_log(logged, "initial generation finalized with errors"))
    end)

    runner.register("mod_manager: phased — a nil-valued escape (error(nil)) still force-finalizes", function()
        -- error(nil) is legal Lua; pcall returns (false, nil), so the escape
        -- must coerce to truthy or the pass would silently skip the force-
        -- finalize and keep loading later entries.
        local logged = {}
        local sb = setup({ order = { "alpha", "beta" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            if p == mod_path("alpha") then error(nil) end
            return mod_file("beta", { init = function() end })
        end
        local mm = new_manager(sb)
        local ticks = 0
        while not mm._adapter:is_load_done() do
            ticks = ticks + 1
            if ticks > 100 then runner.fail("nil escape stalled the pass") end
            mm:update(0.016)
        end
        runner.assert_eq(2, ticks, "the nil escape finalizes on the entry's own tick")
        runner.assert_eq(true, mm._adapter:is_load_done())
        runner.assert_eq("not_loaded", mm._mods[1].state, "the escaping entry stays not_loaded")
        runner.assert_eq("not_loaded", mm._mods[2].state, "remaining entries stay not_loaded")
        runner.assert_nil(mm._mod_load_index)
        runner.assert_not_nil(find_log(logged, "initial mod load pass error:"),
            "the nil escape still logs the pass error line")
    end)

    runner.register("mod_manager: phased — destroy mid-pass settles the pass; a later update loads nothing further", function()
        local sb = setup({ order = { "alpha", "beta" } })
        local execd = {}
        sb.Mods.file.exec_with_return = function(p)
            table.insert(execd, p)
            return ({ [mod_path("alpha")] = mod_file("alpha", { init = function() end }),
                      [mod_path("beta")] = mod_file("beta", { init = function() end }) })[p]
        end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor
        mm:update(0.016)  -- alpha's tick (pass open; beta still pending)
        runner.assert_eq(false, mm._adapter:is_load_done())
        runner.assert_not_nil(mm._load_phase)

        mm:destroy()
        runner.assert_nil(mm._load_phase, "destroy settles the pass fields")
        runner.assert_nil(mm._pass_kind)
        runner.assert_nil(mm._mod_load_index, "destroy clears the load index")
        runner.assert_eq(false, mm._adapter:is_load_done(),
            "destroy is terminal, not a completion (no mark_load_done)")

        local ok, err = pcall(function()
            mm:update(0.016)
            mm:update(0.016)
        end)
        runner.assert_eq(true, ok, "post-destroy updates must not error: " .. tostring(err))
        runner.assert_eq(1, #execd, "no further .mod executed after a mid-pass destroy")
        runner.assert_eq("not_loaded", mm._mods[2].state, "the pending entry never loads")
    end)

    runner.register("mod_manager: phased — _mod_load_index holds entry P after its tick, nil after finalize", function()
        local seen_during_update = nil
        local sb = setup({ order = { "alpha", "beta" } })
        local function outer(name)
            return {
                init = function() end,
                update = function()
                    if name == "alpha" and seen_during_update == nil then
                        seen_during_update = sb.Managers.mod._mod_load_index
                    end
                end,
            }
        end
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("alpha")] = mod_file("alpha", outer("alpha")),
                      [mod_path("beta")] = mod_file("beta", outer("beta")) })[p]
        end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor
        runner.assert_nil(mm._mod_load_index)
        mm:update(0.016)  -- alpha's tick
        runner.assert_eq(1, mm._mod_load_index,
            "index still points at entry 1 after its tick (community parity)")
        runner.assert_eq(1, seen_during_update,
            "the index persists through the same tick's update fan-out")
        mm:update(0.016)  -- beta's tick + finalize
        runner.assert_nil(mm._mod_load_index, "index clears once, at finalize")
    end)

    -- ---------------------------------------------------------------------
    -- on_game_state_changed across the phased pass: dispatch to loaded
    -- entries during the INITIAL pass (community parity — boot transitions
    -- can land inside the multi-tick pass); suppression everywhere else.
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: gsc mid-initial-pass dispatches to already-loaded entries only", function()
        local received = {}
        local sb = setup({ order = { "alpha", "beta" } })
        local function outer(name)
            return {
                init = function() end,
                on_game_state_changed = function(self, status, sname)
                    received[name] = { status, sname }
                end,
            }
        end
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("alpha")] = mod_file("alpha", outer("alpha")),
                      [mod_path("beta")] = mod_file("beta", outer("beta")) })[p]
        end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor
        mm:update(0.016)  -- alpha's tick (beta still not_loaded)
        runner.assert_eq(false, mm._adapter:is_load_done(), "pass still open")

        local sobj = { _name = "StateTitle" }
        local ok, err = pcall(function()
            mm:on_game_state_changed("enter", "StateTitle", sobj)
        end)
        runner.assert_eq(true, ok, "mid-pass gsc must not error: " .. tostring(err))
        runner.assert_eq({ "enter", "StateTitle" }, received.alpha,
            "the loaded entry receives the transition (StateTitle enter lands mid-pass)")
        runner.assert_nil(received.beta,
            "the not-yet-loaded entry receives nothing (no object to dispatch to)")
        runner.assert_eq(false, mm._adapter:is_load_done(), "still not done after the dispatch")
    end)

    runner.register("mod_manager: gsc before the anchor (no pass yet) stays suppressed", function()
        local logged = {}
        local received = 0
        local sb = setup({ order = { "alpha" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("alpha")] = mod_file("alpha", {
                init = function() end,
                on_game_state_changed = function() received = received + 1 end,
            }) })[p]
        end
        local mm = new_manager(sb)  -- scanned, but no update() yet: no pass
        local ok, err = pcall(function()
            mm:on_game_state_changed("exit", "StateSplash", {})
        end)
        runner.assert_eq(true, ok, "pre-anchor gsc must not error: " .. tostring(err))
        runner.assert_eq(0, received, "nothing dispatched before the pass begins")
        runner.assert_eq(1, count_log(logged,
            "on_game_state_changed ignored (reload/load in progress)"),
            "the suppressed window still logs once")
    end)

    runner.register("mod_manager: gsc after a framework stop mid-pass dispatches nothing", function()
        local received = {}
        local sb = setup({ order = { "prior", "dmf" } })
        local function outer(name)
            return {
                init = function()
                    if name == "dmf" then error("framework escape") end
                end,
                on_game_state_changed = function()
                    received[name] = true
                end,
            }
        end
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("prior")] = mod_file("prior", outer("prior")),
                      [mod_path("dmf")] = mod_file("dmf", outer("dmf")) })[p]
        end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor
        mm:update(0.016)  -- prior loads
        mm:update(0.016)  -- dmf init raises -> framework stop
        runner.assert_eq(true, mm._generation_failed, "sanity: generation stopped")
        runner.assert_eq(true, mm._adapter:is_load_done(), "pass finalized on the failure tick")

        local ok, err = pcall(function()
            mm:on_game_state_changed("enter", "StateTitle", {})
        end)
        runner.assert_eq(true, ok, "post-stop gsc must not error: " .. tostring(err))
        runner.assert_nil(next(received),
            "the stopped generation dispatches nothing (early return)")
    end)

    runner.register("mod_manager: a gsc failure mid-initial-pass isolates without stalling the pass", function()
        local logged = {}
        local sb = setup({ order = { "boom", "good" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("boom")] = mod_file("boom", {
                    init = function() end,
                    on_game_state_changed = function() error("gsc boom") end,
                }),
                [mod_path("good")] = mod_file("good", {
                    init = function() end,
                    on_game_state_changed = function() end,
                }),
            })[p]
        end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor
        mm:update(0.016)  -- boom's tick
        runner.assert_eq("running", mm._mods[1].state)

        mm:on_game_state_changed("enter", "StateTitle", {})  -- boom raises
        runner.assert_eq("disabled", mm._mods[1].state,
            "the one-strike containment disabled the failing entry")
        runner.assert_eq(false, mm._adapter:is_load_done(), "the pass is still open")

        mm:update(0.016)  -- good's own tick — the pass advances normally
        runner.assert_eq(true, mm._adapter:is_load_done())
        runner.assert_eq("running", mm._mods[2].state,
            "the sibling still loads on its own tick (pass unaffected)")
        runner.assert_not_nil(find_log(logged, "mod 'boom' on_game_state_changed failed"))
        runner.assert_eq(1, #mm._failure_records)
        runner.assert_eq(1, mm._failure_records[1].generation,
            "the failure record carries the pass's target generation")
    end)

    runner.register("mod_manager: a gsc-driven framework failure mid-initial-pass stops + finalizes cleanly", function()
        -- The composition the gsc gate makes reachable: dmf's outer
        -- on_game_state_changed raises AFTER its load tick (prior loaded,
        -- later still unloaded). The framework path fires FROM the dispatch
        -- (stop flag set, loaded outers reverse-cleaned on that tick), an
        -- interim gsc dispatches nothing (gate open, _generation_failed early
        -- return), and the NEXT tick finalizes the stopped pass.
        local logged = {}
        local seq = {}
        local unloads = {}
        local sb = setup({ order = { "prior", "dmf", "later" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("prior")] = mod_file("prior", {
                    init = function() table.insert(seq, "prior:init") end,
                    on_game_state_changed = function(_, status)
                        table.insert(seq, "prior:gsc:" .. status)
                    end,
                    on_unload = function() table.insert(unloads, "prior") end,
                }),
                [mod_path("dmf")] = mod_file("dmf", {
                    init = function() table.insert(seq, "dmf:init") end,
                    on_game_state_changed = function() error("framework gsc boom") end,
                    on_unload = function() table.insert(unloads, "dmf") end,
                }),
                [mod_path("later")] = mod_file("later", {
                    init = function() table.insert(seq, "later:init") end,
                }),
            })[p]
        end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor
        mm:update(0.016)  -- prior's tick
        mm:update(0.016)  -- dmf's load tick (init fine; later still unloaded)
        runner.assert_eq(false, mm._adapter:is_load_done(), "pass open after dmf's tick")

        local ok, err = pcall(function()
            mm:on_game_state_changed("enter", "StateTitle", {})
        end)
        runner.assert_eq(true, ok, "the framework gsc raise must be contained: " .. tostring(err))
        runner.assert_eq(true, mm._generation_failed, "the framework path fired from gsc")
        runner.assert_eq(true, mm._stop_load_pass, "the stop flag is set")
        runner.assert_eq({ "dmf", "prior" }, unloads,
            "loaded outers reverse-cleaned on the gsc tick")
        runner.assert_not_nil(find_log(logged, "framework-boundary lifecycle failure"))
        runner.assert_eq(1, #mm._failure_records)
        runner.assert_eq(true, mm._failure_records[1].framework)

        -- Interim gsc before the next tick: gate OPEN (initial pass), so no
        -- suppressed log — and the _generation_failed early return dispatches
        -- nothing (no further callbacks, no double teardown).
        runner.assert_not_nil(mm._load_phase, "the stopped pass is still open")
        local ok2, err2 = pcall(function()
            mm:on_game_state_changed("exit", "StateTitle", {})
        end)
        runner.assert_eq(true, ok2, "the interim gsc must not error: " .. tostring(err2))
        runner.assert_eq(0, count_log(logged, "on_game_state_changed ignored"),
            "no suppressed log: the gate is open mid-initial-pass")
        runner.assert_eq({ "dmf", "prior" }, unloads, "no additional teardown")
        runner.assert_eq(false, mm._adapter:is_load_done(), "finalize waits for the next tick")

        mm:update(0.016)  -- the finalize tick
        runner.assert_eq(true, mm._adapter:is_load_done())
        runner.assert_eq("skipped", mm._mods[3].state, "later never loaded -> skipped")
        local later_ran = false
        for _, tag in ipairs(seq) do
            if tag == "later:init" then later_ran = true end
        end
        runner.assert_eq(false, later_ran, "later:init never ran")
        runner.assert_eq(1, mm._generation)
        runner.assert_eq("stopped", mm._mods[1].state)
        runner.assert_eq("disabled", mm._mods[2].state)
    end)

    runner.register("mod_manager: gsc after a mid-pass destroy dispatches nothing", function()
        -- This stages the never-finalized destroy variant, where the gate is
        -- CLOSED via the not-done branch — so the suppressed-log assertion
        -- below pins the GATE (received == 0 alone would also pass with the
        -- gate open, since destroy empties the entry objects either way).
        local logged = {}
        local received = 0
        local sb = setup({ order = { "alpha", "beta" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("alpha")] = mod_file("alpha", {
                        init = function() end,
                        on_game_state_changed = function() received = received + 1 end,
                    }),
                      [mod_path("beta")] = mod_file("beta", { init = function() end }) })[p]
        end
        local mm = new_manager(sb)
        mm:update(0.016)  -- anchor
        mm:update(0.016)  -- alpha's tick (pass open)
        mm:destroy()      -- settles the pass: fields nil -> suppressed again

        local ok, err = pcall(function()
            mm:on_game_state_changed("enter", "StateTitle", {})
        end)
        runner.assert_eq(true, ok, "post-destroy gsc must not error: " .. tostring(err))
        runner.assert_eq(0, received,
            "nothing dispatched after destroy settles the pass")
        runner.assert_eq(1, count_log(logged,
            "on_game_state_changed ignored (reload/load in progress)"),
            "the gate itself is closed (suppressed window logs once)")
    end)

    -- ---------------------------------------------------------------------
    -- Startup trace diagnostics (FRAME_INDEX-stamped load-pass events)
    -- ---------------------------------------------------------------------

    runner.register("mod_manager: successful scan emits the DEBUG scan summary", function()
        local logged = {}
        local sb = setup({ order = { "alpha", "beta" } })
        sb.__print = function(m) table.insert(logged, m) end
        new_manager(sb)  -- scan runs in :new()
        runner.assert_eq(1, count_log(logged, "scan: 2 entries from mods.lst"),
            "exactly one scan summary naming the entry count")
        -- An empty mods.lst still produces a sensible 0-entries line.
        local logged2 = {}
        local sb2 = setup({ order = {} })
        sb2.__print = function(m) table.insert(logged2, m) end
        local mm2 = load_driver(sb2):new()
        mm2._adapter:establish()
        runner.assert_eq(1, count_log(logged2, "scan: 0 entries from mods.lst"),
            "empty mods.lst yields the 0-entries summary")
    end)

    runner.register("mod_manager: initial pass TRACE lines (begin, per-entry, summary) when trace on", function()
        local logged = {}
        local sb = setup({ order = { "dmfmod", "good" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods._relay._trace_enabled = true
        sb.FRAME_INDEX = -1  -- engine initializes FRAME_INDEX to -1 in main.lua
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("dmfmod")] = { run = function() end },  -- nil result: DMF-driven
                [mod_path("good")] = mod_file("good", { init = function() end }),
            })[p]
        end
        new_loaded(sb)
        runner.assert_eq(1, count_log(logged, "load pass begin (initial)"),
            "one pass-begin line")
        runner.assert_eq(1, count_log(logged, "load entry #1 'dmfmod'"), "entry 1 begin line")
        runner.assert_eq(1, count_log(logged, "entry 'dmfmod' result=dmf_driven"),
            "entry 1 outcome line (dmf_driven)")
        runner.assert_eq(1, count_log(logged, "load entry #2 'good'"), "entry 2 begin line")
        runner.assert_eq(1, count_log(logged, "entry 'good' result=running"),
            "entry 2 outcome line (running)")
        runner.assert_eq(1, count_log(logged, "initial load pass complete: 2 entries, 0 failed"),
            "the completion summary names totals")
        local begin_line = find_log(logged, "load pass begin (initial)")
        runner.assert_truthy(begin_line:find("^TRACE %[mod_loader%] ") ~= nil,
            "the begin line carries the TRACE community prefix")
        runner.assert_truthy(begin_line:find(" frame=%-1$", 1, false) ~= nil,
            "TRACE lines carry the FRAME_INDEX stamp (negative included)")
    end)

    runner.register("mod_manager: failure outcomes land in the entry outcome lines", function()
        local logged = {}
        local sb = setup({ order = { "boom", "good" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods._relay._trace_enabled = true
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("boom")] = { run = function() error("run boom") end },
                [mod_path("good")] = mod_file("good", { init = function() end }),
            })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq(1, count_log(logged, "entry 'boom' result=failed"),
            "a failed run reports result=failed")
        runner.assert_eq(1, count_log(logged, "initial load pass complete: 2 entries, 1 failed"),
            "the summary counts the failed entry")
        runner.assert_eq("failed", mm._mods[1].state)
    end)

    runner.register("mod_manager: framework stop marks later entries result=skipped", function()
        local logged = {}
        local sb = setup({ order = { "dmf", "later" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods._relay._trace_enabled = true
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("dmf")] = mod_file("dmf", recording_mod("dmf", {}, "init")),
                [mod_path("later")] = mod_file("later", { init = function() end }),
            })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq(1, count_log(logged, "entry 'dmf' result=disabled"),
            "the framework-boundary entry reports result=disabled")
        runner.assert_eq(1, count_log(logged, "entry 'later' result=skipped"),
            "entries after a generation stop report result=skipped")
    end)

    runner.register("mod_manager: trace off — no TRACE lines, existing per-entry lines unchanged", function()
        local logged = {}
        local sb = setup({ order = { "dmfmod", "ghost" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            if p == mod_path("ghost") then return false end  -- missing .mod
            return ({ [mod_path("dmfmod")] = { run = function() end } })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq(0, count_log(logged, "TRACE "),
            "trace off: zero TRACE-prefixed lines")
        runner.assert_eq(0, count_log(logged, "load entry "),
            "trace off: no per-entry begin lines")
        runner.assert_eq(0, count_log(logged, "result="),
            "trace off: no per-entry outcome lines")
        -- The EXISTING per-entry diagnostics keep firing at their own levels.
        runner.assert_eq(1, count_log(logged, "mod 'dmfmod' DMF-driven (run returned no object)"),
            "the existing DMF-driven DEBUG line is unchanged")
        runner.assert_eq(1, count_log(logged, "mod 'ghost' .mod missing, unreadable, or failed to execute"),
            "the existing missing-.mod ERROR line is unchanged")
        -- The low-volume DEBUG additions are present exactly once each.
        runner.assert_eq(1, count_log(logged, "scan: 2 entries from mods.lst"))
        runner.assert_eq(1, count_log(logged, "initial load pass complete: 2 entries, 1 failed"))
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
        local mm = new_manager(sb)
        -- 1-entry list: anchor tick, then the entry tick (load + finalize in
        -- one tick) — the mod's FIRST update fires on its own load tick.
        tick_to_done(mm)
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
        runner.assert_not_nil(find_log(logged, "mod 'boom' update failed"))
    end)

    runner.register("mod_manager: update skips mods without update() (no error)", function()
        local logged = {}
        local sb = setup({ order = { "dmf" } })
        sb.__print = function(m) table.insert(logged, m) end
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("dmf")] = mod_file("dmf", { init = function() end }) })[p]
        end
        local mm = new_manager(sb)
        local ok, err = pcall(function() tick_to_done(mm) end)
        runner.assert_eq(true, ok, tostring(err))
        runner.assert_eq(0, count_error_level(logged),
            "a clean load pass logs no WARN/ERROR lines")
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
        runner.assert_not_nil(find_log(logged, "mod 'boom' on_game_state_changed failed"))
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
        runner.assert_not_nil(find_log(logged, "mod 'beta' on_unload failed"))
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
        runner.assert_eq(0, count_error_level(logged),
            "a clean load + destroy logs no WARN/ERROR lines")
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
        -- Load the REAL file.lua + REAL dmf_adapter.lua + REAL mod_manager.lua
        -- in one sandbox, wiring the adapter the way the chassis does (loaded
        -- once, published on Mods._relay.dmf_adapter; the manager's init reads
        -- it from there, and the chassis Step-1c built-in path uses the
        -- manager's own adapter to establish + register the real file.lua
        -- observer). Execute a real staged chunk through Mods.file.dofile that
        -- surfaces a DMFMod io surface; verify the real observer adapts before
        -- any Phase-2 call uses the method, and that the adapter diagnostic
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
        mock.attach_logger(sb)

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
        -- file.lua loads path.lua via Mods.load_module at its module top; wire
        -- the generic source loader (dmf_adapter is NOT served through here —
        -- the chassis loads it exactly once, simulated below).
        sb.Mods.load_module = function(name)
            return mock.run_module(name, sb)
        end

        -- Load real file.lua, then simulate the chassis module-scope load of
        -- dmf_adapter (published on Mods._relay before mod_manager loads), then
        -- load real mod_manager.lua (shares the sandbox).
        mock.run_module("file", sb)
        sb.Mods._relay.dmf_adapter = mock.run_module("dmf_adapter", sb)
        mock.run_module("mod_manager", sb)

        local mm = registry.ModManager:new()
        -- Chassis Step-1c built-in path: the manager's own adapter establishes
        -- and registers the real observer (exactly one registering instance).
        mm._adapter:establish()
        mm._adapter:register_io_observer()
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

    runner.register("mod_manager: _mods[_mod_load_index].data is the descriptor table during run() (DMF expectation)", function()
        -- DMF's DMFMod:init reads _mods[_mod_load_index].data (then .packages)
        -- during mod construction, which happens synchronously inside run()
        -- (new_mod) — so the manager must publish the executed descriptor on
        -- the entry BEFORE invoking run().
        local sb = setup({ order = { "usermod" } })
        local seen = {}
        local descriptor = {
            packages = { "some/package" },
            run = function()
                local m = sb.Managers.mod
                local entry = m._mods[m._mod_load_index]
                seen.data = entry and entry.data
                seen.packages = seen.data and seen.data.packages
                -- DMF convention: side-effect registration, no return.
            end,
        }
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("usermod")] = descriptor })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq(descriptor, seen.data,
            "entry.data must be the descriptor table itself, published before run()")
        runner.assert_eq({ "some/package" }, seen.packages,
            "a .packages field on the descriptor is visible via entry.data during run()")
        runner.assert_eq("dmf_driven", mm._mods[1].state)
    end)

    runner.register("mod_manager: entry.data stays unpublished when the descriptor is invalid (no run)", function()
        local sb = setup({ order = { "bad", "good" } })
        sb.Mods.file.exec_with_return = function(p)
            return ({
                [mod_path("bad")] = { packages = { "p" } },  -- table, but no run
                [mod_path("good")] = mod_file("good", { init = function() end }),
            })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq("failed", mm._mods[1].state)
        runner.assert_nil(mm._mods[1].data,
            "an entry whose descriptor never passed validation carries no .data")
        runner.assert_truthy(mm._mods[2].data ~= nil,
            "the valid sibling still publishes its descriptor")
    end)

    runner.register("mod_manager: a failed run leaves stale entry.data (deliberately not cleared)", function()
        -- Nothing reads .data of a failed entry (_mod_load_index only points
        -- at an entry during its own _load_one), so no clearing logic exists.
        local sb = setup({ order = { "boom" } })
        local descriptor = mod_file("boom", nil, nil, true)  -- run raises
        sb.Mods.file.exec_with_return = function(p)
            return ({ [mod_path("boom")] = descriptor })[p]
        end
        local mm = new_loaded(sb)
        runner.assert_eq("failed", mm._mods[1].state)
        runner.assert_eq(descriptor, mm._mods[1].data,
            "publication precedes run(); a failed run does not unwind it")
    end)
end
