-- test_loader_hardening.lua — diagnostics and outer-failure hardening.
-- Relay-owned fakes only: no community loader/framework implementation is
-- reproduced here. The tests assert the consolidated behavioral contract.

local mock = require("mock")

return function(runner)
    local function contains(lines, text)
        for _, line in ipairs(lines) do
            if type(line) == "string" and line:find(text, 1, true) then
                return line
            end
        end
        return nil
    end

    local function count_contains(lines, text)
        local count = 0
        for _, line in ipairs(lines) do
            if type(line) == "string" and line:find(text, 1, true) then
                count = count + 1
            end
        end
        return count
    end

    local function setup(opts)
        opts = opts or {}
        local sb = mock.new_sandbox()
        local registry = {}
        local function declare(name)
            local class = { name = name }
            class.__index = class
            class.new = function(self, ...)
                local instance = setmetatable({}, class)
                if class.init then class.init(instance, ...) end
                return instance
            end
            registry[name] = class
            return class
        end
        sb.class = setmetatable({}, { __call = function(_, ...) return declare(...) end })

        local logs = {}
        sb.__print = function(message) logs[#logs + 1] = message end
        local alerts = {}
        sb.Managers = {}
        if opts.event ~= false then
            sb.Managers.event = {
                trigger = function(self, event_name, message_type, data)
                    if opts.throw_alert then error("alert transport boom") end
                    alerts[#alerts + 1] = {
                        event_name = event_name,
                        message_type = message_type,
                        data = data,
                    }
                end,
            }
        end

        local crash_calls = {}
        if opts.crashify ~= false then
            sb.Crashify = {
                print_property = function(key, value)
                    if opts.throw_crashify_print then error("crash publish boom") end
                    crash_calls[#crash_calls + 1] = { "print", key, value }
                end,
                remove_print_property = function(key)
                    if opts.throw_crashify_remove then error("crash remove boom") end
                    crash_calls[#crash_calls + 1] = { "remove", key }
                end,
            }
        end

        local version = opts.version
        if version == nil then version = "0.3.0-beta.2" end
        sb.Mods = {
            file = {},
            require_store = {},
            _relay = {
                version = version,
                traceback = opts.traceback or function(message)
                    return "TRACEBACK:" .. message
                end,
            },
        }
        mock.attach_logger(sb)
        -- The chassis (lifecycle.lua module scope) loads dmf_adapter exactly
        -- once and publishes it on Mods._relay.dmf_adapter; mod_manager's init
        -- reads it from there. Simulate that chassis load (the real wiring is
        -- covered by test_lifecycle).
        sb.Mods._relay.dmf_adapter = mock.run_module("dmf_adapter", sb)
        sb.Mods.file.add_observer = function() end
        local retire_count = 0
        sb.Mods.retire_class = function(name)
            if name == "DMFMod" then retire_count = retire_count + 1 end
            sb[name] = nil
        end

        local developer_mode = opts.developer_mode
        if developer_mode == nil then developer_mode = true end
        sb.Application = {
            user_setting = function()
                return { developer_mode = developer_mode }
            end,
        }
        sb.Keyboard = {
            button_index = function(name)
                return ({ r = 1, ["left shift"] = 2, ["left ctrl"] = 3 })[name]
            end,
            pressed = function() return false end,
            button = function() return 0 end,
        }

        local state = opts.state or { order = {}, mods = {} }
        sb.Mods.file.read_content_to_table = function() return state.order end
        sb.Mods.file.exec_with_return = function(path)
            for name, descriptor in pairs(state.mods) do
                if path == name .. "/" .. name .. ".mod" then return descriptor end
            end
            return false
        end

        local ModManager = mock.run_module("mod_manager", sb)
        local manager = ModManager:new()
        -- Chassis Step-1c built-in path: the manager's own adapter establishes
        -- (Managers.mod publication + settings restore-if-nil). The Crashify
        -- version publication is chassis-owned too (lifecycle.lua) and is not
        -- driven here — these tests assert the manager's own per-mod metadata
        -- boundary. The real chassis wiring is covered by test_lifecycle.
        manager._adapter:establish()
        return {
            sb = sb,
            manager = manager,
            class = ModManager,
            state = state,
            logs = logs,
            alerts = alerts,
            crash_calls = crash_calls,
            retire_count = function() return retire_count end,
        }
    end

    local function descriptor(result, before_return)
        return {
            run = function()
                if before_return then before_return() end
                return result
            end,
        }
    end

    -- Drive manager:update(0.1) until the staged load pass finalizes (anchor
    -- update + one entry per update). Bounded; asserts completion. Returns the
    -- updates driven.
    local function update_to_done(env, bound)
        bound = bound or 100
        local updates = 0
        while not env.manager._adapter:is_load_done() do
            updates = updates + 1
            if updates > bound then
                runner.fail("load pass did not finalize within " .. bound .. " updates")
            end
            env.manager:update(0.1)
        end
        return updates
    end

    -- Drive one full reload: the teardown update, then the staged replacement
    -- pass to completion.
    local function reload_to_done(env)
        env.manager:update(0.1)  -- teardown frame
        update_to_done(env)        -- anchor + one entry per update
    end

    runner.register("hardening: every non-nil non-table run result is isolated before inspection", function()
        local tostring_called = false
        local proxy = newproxy(true)
        getmetatable(proxy).__tostring = function()
            tostring_called = true
            error("must not stringify")
        end
        local values = {
            { tag = "false", value = false },
            { tag = "true", value = true },
            { tag = "zero", value = 0 },
            { tag = "number", value = 42 },
            { tag = "string", value = "bad" },
            { tag = "function", value = function() end },
            { tag = "thread", value = coroutine.create(function() end) },
            { tag = "userdata", value = proxy },
        }
        local env = setup()
        local initialized = 0
        for _, item in ipairs(values) do
            local bad = "bad_" .. item.tag
            local good = "good_" .. item.tag
            env.state.order[#env.state.order + 1] = bad
            env.state.order[#env.state.order + 1] = good
            env.state.mods[bad] = descriptor(item.value)
            env.state.mods[good] = descriptor({
                init = function() initialized = initialized + 1 end,
            })
        end
        -- Rescan because setup intentionally constructed before staging.
        env.manager:_scan_mods()
        update_to_done(env)

        runner.assert_eq("done", env.manager._state)
        runner.assert_eq(1, env.manager._generation)
        runner.assert_nil(env.manager._mod_load_index)
        runner.assert_eq(#values, initialized)
        runner.assert_eq(false, tostring_called, "invalid userdata was never stringified")
        for i = 1, #values do
            local bad_entry = env.manager._mods[(i - 1) * 2 + 1]
            local good_entry = env.manager._mods[(i - 1) * 2 + 2]
            runner.assert_eq("failed", bad_entry.state)
            runner.assert_nil(bad_entry.object)
            runner.assert_eq("running", good_entry.state)
            runner.assert_not_nil(good_entry.object)
        end
    end)

    runner.register("hardening: unexpected initial load throw always finalizes and permits reload", function()
        local env = setup()
        -- Stage one entry so the per-entry load step actually runs (an empty
        -- pass performs no load step at all).
        env.state.order = { "alpha" }
        env.state.mods = { alpha = descriptor({}) }
        env.manager:_scan_mods()
        local real_load_step = env.manager._load_pass_entry
        env.manager._load_pass_entry = function() error("unexpected initial pass boom") end
        local ok = pcall(function() update_to_done(env) end)
        runner.assert_eq(true, ok)
        runner.assert_eq("done", env.manager._state)
        runner.assert_eq(1, env.manager._generation)
        runner.assert_nil(env.manager._mod_load_index)
        runner.assert_not_nil(contains(env.logs, "initial generation finalized with errors"))

        env.manager._load_pass_entry = real_load_step
        runner.assert_eq(true, env.manager:request_reload("test"))
        reload_to_done(env)
        runner.assert_eq("done", env.manager._state)
        runner.assert_eq(2, env.manager._generation)
    end)

    runner.register("hardening: malformed replacement result finalizes degraded and clears reload bookkeeping", function()
        local env = setup()
        env.state.order = { "alpha" }
        env.state.mods = { alpha = descriptor({}) }
        env.manager:_scan_mods()
        update_to_done(env)
        env.state.mods = { alpha = descriptor("invalid replacement") }
        env.manager:request_reload("test")
        reload_to_done(env)
        runner.assert_eq("done", env.manager._state)
        runner.assert_eq(2, env.manager._generation)
        runner.assert_eq("failed", env.manager._mods[1].state)
        runner.assert_nil(env.manager._mods[1].object)
        runner.assert_nil(env.manager._mod_load_index)
        runner.assert_nil(env.manager._reload_data)
        runner.assert_eq(false, env.manager._reload_in_progress)
        runner.assert_not_nil(contains(env.logs, "completed with errors"))
    end)

    runner.register("hardening: accepted descriptors publish keys in load order; run outcomes retain keys", function()
        -- The process-lifetime ModRelay:Version property is chassis-owned
        -- (lifecycle Step 1c — covered in test_lifecycle, where it precedes any
        -- per-mod key). Here: the manager publishes only per-mod keys, in load
        -- order, and run outcomes (throw / nil-driven / scalar / outer) retain
        -- their publication.
        local env = setup()
        local sequence = {}
        env.sb.Crashify.print_property = function(key, value)
            env.crash_calls[#env.crash_calls + 1] = { "print", key, value }
            sequence[#sequence + 1] = "crash:" .. key
        end
        env.state.order = { "missing", "invalid", "throws", "nilmod", "scalar", "outer" }
        env.state.mods = {
            invalid = { no_run = true },
            throws = { run = function() sequence[#sequence + 1] = "run:throws"; error("boom") end },
            nilmod = { run = function() sequence[#sequence + 1] = "run:nilmod" end },
            scalar = { run = function() sequence[#sequence + 1] = "run:scalar"; return 7 end },
            outer = { run = function() sequence[#sequence + 1] = "run:outer"; return {} end },
        }
        env.manager:_scan_mods()
        update_to_done(env)

        for _, call in ipairs(env.crash_calls) do
            runner.assert_truthy(call[2] ~= "ModRelay:Version",
                "the manager must not publish the chassis-owned version key")
        end
        runner.assert_eq("crash:Mod:throws", sequence[1])
        runner.assert_eq("run:throws", sequence[2])
        runner.assert_eq("crash:Mod:nilmod", sequence[3])
        runner.assert_eq("run:nilmod", sequence[4])
        runner.assert_eq("crash:Mod:scalar", sequence[5])
        runner.assert_eq("run:scalar", sequence[6])
        runner.assert_eq("crash:Mod:outer", sequence[7])
        runner.assert_eq("run:outer", sequence[8])
        runner.assert_nil(contains(sequence, "crash:Mod:missing"))
        runner.assert_nil(contains(sequence, "crash:Mod:invalid"))
    end)

    runner.register("hardening: descriptor run lookup errors fail only that entry and earn no property", function()
        local env = setup()
        local initialized = 0
        local malformed = setmetatable({}, {
            __index = function(_, key)
                if key == "run" then error("descriptor lookup boom") end
            end,
        })
        env.state.order = { "malformed", "good" }
        env.state.mods = {
            malformed = malformed,
            good = descriptor({ init = function() initialized = initialized + 1 end }),
        }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq("failed", env.manager._mods[1].state)
        runner.assert_eq("running", env.manager._mods[2].state)
        runner.assert_eq(1, initialized)
        runner.assert_eq("done", env.manager._state)
        for _, call in ipairs(env.crash_calls) do
            runner.assert_truthy(call[2] ~= "Mod:malformed")
        end
    end)

    runner.register("hardening: manager never publishes or removes the chassis version key; stale mod keys rotate on reload", function()
        -- The ModRelay:Version property is chassis-owned and process-lifetime
        -- (published once at manager creation — asserted in test_lifecycle).
        -- Manager-scope boundary: across reload generations the manager never
        -- prints or removes the version key, while tracked per-mod keys rotate.
        local env = setup()
        env.state.order = { "alpha", "beta" }
        env.state.mods = { alpha = descriptor({}), beta = descriptor({}) }
        env.manager:_scan_mods()
        update_to_done(env)
        env.state.order = { "beta", "gamma" }
        env.state.mods = { beta = descriptor({}), gamma = descriptor({}) }
        env.manager:request_reload("test")
        reload_to_done(env)
        env.manager:destroy()

        local version_prints, version_removes = 0, 0
        local removed, printed = {}, {}
        for _, call in ipairs(env.crash_calls) do
            if call[1] == "print" then
                printed[call[2]] = (printed[call[2]] or 0) + 1
                if call[2] == "ModRelay:Version" then version_prints = version_prints + 1 end
            else
                removed[call[2]] = true
                if call[2] == "ModRelay:Version" then version_removes = version_removes + 1 end
            end
        end
        runner.assert_eq(0, version_prints,
            "the manager must never publish the chassis-owned version key")
        runner.assert_eq(0, version_removes,
            "the version key is process-lifetime and never removed")
        runner.assert_eq(true, removed["Mod:alpha"])
        runner.assert_eq(true, removed["Mod:beta"])
        runner.assert_eq(2, printed["Mod:beta"])
        runner.assert_eq(1, printed["Mod:gamma"])
    end)

    runner.register("hardening: empty order publishes no keys; removal failure retries next generation", function()
        local env = setup()
        env.state.order = {}
        env.manager:_scan_mods()
        env.manager:update(0.1)  -- empty list: anchor update begins AND finalizes
        runner.assert_eq(0, #env.crash_calls,
            "an empty order publishes no per-mod keys (version is chassis-owned)")

        env.state.order = { "alpha" }
        env.state.mods = { alpha = descriptor({}) }
        env.manager:request_reload("test")
        reload_to_done(env)
        runner.assert_eq("running", env.manager._mods[1].state)

        env.sb.Crashify.remove_print_property = function() error("remove failure") end
        env.manager:request_reload("test")
        reload_to_done(env)
        runner.assert_eq("done", env.manager._state)
        runner.assert_eq(3, env.manager._generation)
        runner.assert_eq("running", env.manager._mods[1].state)

        local recovered_publications = 0
        env.sb.Crashify.remove_print_property = function(key)
            env.crash_calls[#env.crash_calls + 1] = { "remove", key }
        end
        env.sb.Crashify.print_property = function(key, value)
            env.crash_calls[#env.crash_calls + 1] = { "print", key, value }
            if key == "Mod:alpha" then recovered_publications = recovered_publications + 1 end
        end
        env.manager:request_reload("test")
        reload_to_done(env)
        runner.assert_eq(4, env.manager._generation)
        runner.assert_eq(1, recovered_publications,
            "Crashify operations resume at a later generation boundary")
    end)

    runner.register("hardening: unavailable Crashify skips per-mod keys once and recovers on a later generation", function()
        -- Manager scope: with Crashify absent, per-mod metadata is skipped with
        -- a single unavailable log; the load itself is unaffected, and a later
        -- generation (Crashify now present) publishes normally. The chassis
        -- version publication's own unavailable/late-appearance retry is
        -- covered in test_lifecycle.
        local env = setup({ crashify = false })
        env.state.order = { "alpha" }
        env.state.mods = { alpha = descriptor({}) }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq("running", env.manager._mods[1].state)
        runner.assert_eq("done", env.manager._state)
        runner.assert_eq(1, count_contains(env.logs, "Crashify unavailable"))
        runner.assert_eq(0, #env.crash_calls)

        env.sb.Crashify = {
            print_property = function(key, value)
                env.crash_calls[#env.crash_calls + 1] = { "print", key, value }
            end,
            remove_print_property = function(key)
                env.crash_calls[#env.crash_calls + 1] = { "remove", key }
            end,
        }
        env.manager:request_reload("test")
        reload_to_done(env)
        runner.assert_eq(1, count_contains(env.logs, "Crashify unavailable"),
            "the unavailable log stays once after recovery")
        runner.assert_eq("Mod:alpha", env.crash_calls[1][2])
    end)

    runner.register("hardening: metadata rejects unsafe names without changing load behavior or leaking raw names", function()
        local control_name = "unsafe\nname"
        local long_name = string.rep("x", 121)
        local env = setup()
        env.state.order = { "", control_name, long_name, "dupe", "dupe" }
        env.state.mods = {
            [""] = descriptor(nil),
            [control_name] = descriptor(nil),
            [long_name] = descriptor(nil),
            dupe = descriptor(nil),
        }
        env.manager:_scan_mods()
        update_to_done(env)
        for _, entry in ipairs(env.manager._mods) do
            runner.assert_eq("dmf_driven", entry.state)
        end
        local dupe_prints = 0
        for _, call in ipairs(env.crash_calls) do
            if call[2] == "Mod:dupe" then dupe_prints = dupe_prints + 1 end
            runner.assert_truthy(call[2] ~= "Mod:" .. control_name)
            runner.assert_truthy(call[2] ~= "Mod:" .. long_name)
        end
        runner.assert_eq(1, dupe_prints)
        for _, line in ipairs(env.logs) do
            runner.assert_truthy(not line:find(control_name, 1, true), "raw control name leaked")
            runner.assert_truthy(not line:find(long_name, 1, true), "raw oversized name leaked")
        end
    end)

    runner.register("hardening: Crashify mod-publication throws are generation-local and never alter load or reload finalization", function()
        -- Manager scope: a throwing print_property during a per-mod publication
        -- disables crash metadata for that generation only; the load completes
        -- and a later generation retries. (The chassis version publication's
        -- own throw containment is covered in test_lifecycle.)
        local env = setup({ throw_crashify_print = true })
        env.state.order = { "alpha" }
        env.state.mods = { alpha = descriptor({}) }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq("running", env.manager._mods[1].state)
        runner.assert_eq("done", env.manager._state)
        runner.assert_eq(0, #env.crash_calls, "generation 1 published nothing (throw contained)")
        runner.assert_eq(1, count_contains(env.logs, "Crashify mod publication failed"))
        runner.assert_eq(1, count_contains(env.logs, "crash metadata disabled for this generation"))

        env.sb.Crashify.print_property = function(key, value)
            env.crash_calls[#env.crash_calls + 1] = { "print", key, value }
        end
        env.manager:request_reload("test")
        reload_to_done(env)
        runner.assert_eq(2, env.manager._generation)
        runner.assert_eq("done", env.manager._state)
        runner.assert_eq("Mod:alpha", env.crash_calls[1][2],
            "the next generation republishes per-mod keys (throw was generation-local)")
    end)

    runner.register("hardening: init update and state failures disable once, unload once, and preserve siblings", function()
        local callbacks = { "init", "update", "on_game_state_changed" }
        for _, callback in ipairs(callbacks) do
            local env = setup()
            local calls, unloads, sibling = 0, 0, 0
            local failing = {
                init = function()
                    if callback == "init" then calls = calls + 1; error("callback boom") end
                end,
                update = function()
                    if callback == "update" then calls = calls + 1; error("callback boom") end
                end,
                on_game_state_changed = function()
                    if callback == "on_game_state_changed" then calls = calls + 1; error("callback boom") end
                end,
                on_reload = function() error("must never run") end,
                on_unload = function() unloads = unloads + 1 end,
            }
            env.state.order = { "bad", "good" }
            env.state.mods = {
                bad = descriptor(failing),
                good = descriptor({
                    init = function() sibling = sibling + 1 end,
                    update = function() sibling = sibling + 1 end,
                    on_game_state_changed = function() sibling = sibling + 1 end,
                }),
            }
            env.manager:_scan_mods()
            update_to_done(env)
            if callback == "on_game_state_changed" then
                env.manager:on_game_state_changed("enter", "StateGame", {})
            end
            env.manager:update(0.1)
            env.manager:on_game_state_changed("enter", "StateGame", {})
            runner.assert_eq(1, calls, callback .. " must not retry")
            runner.assert_eq(1, unloads, callback .. " cleanup exactly once")
            runner.assert_eq("disabled", env.manager._mods[1].state)
            runner.assert_nil(env.manager._mods[1].object)
            runner.assert_truthy(sibling > 0, "healthy sibling continues")
            runner.assert_eq(1, #env.manager._failure_records)
        end
    end)

    runner.register("hardening: callback lookup and unprintable errors produce one safe traced diagnostic", function()
        local env = setup()
        local lookup_count, unloads = 0, 0
        local object = {
            init = function() end,
            on_unload = function() unloads = unloads + 1 end,
        }
        setmetatable(object, {
            __index = function(_, key)
                if key == "update" then
                    lookup_count = lookup_count + 1
                    local err = setmetatable({}, { __tostring = function() error("format boom") end })
                    error(err)
                end
            end,
        })
        env.state.order = { "unsafe\nentry" }
        env.state.mods = { ["unsafe\nentry"] = descriptor(object) }
        env.manager:_scan_mods()
        local ok = pcall(function() update_to_done(env) end)
        runner.assert_eq(true, ok)
        runner.assert_eq(1, lookup_count)
        runner.assert_eq(1, unloads)
        runner.assert_eq("disabled", env.manager._mods[1].state)
        local diagnostic = contains(env.logs, "<unprintable error>")
        runner.assert_not_nil(diagnostic)
        runner.assert_not_nil(diagnostic:find("TRACEBACK:", 1, true))
        runner.assert_nil(diagnostic:find("unsafe\nentry", 1, true))
        runner.assert_not_nil(diagnostic:find("unsafe?entry", 1, true))
        runner.assert_not_nil(diagnostic:find("generation 1", 1, true))
    end)

    runner.register("hardening: traceback and failure-cleanup errors cannot recurse or wedge", function()
        local env = setup({ traceback = function() error("traceback helper boom") end })
        local updates, unloads = 0, 0
        env.state.order = { "bad", "good" }
        env.state.mods = {
            bad = descriptor({
                update = function() updates = updates + 1; error("outer boom") end,
                on_unload = function() unloads = unloads + 1; error("cleanup boom") end,
            }),
            good = descriptor({ update = function() updates = updates + 1 end }),
        }
        env.manager:_scan_mods()
        local ok = pcall(function() update_to_done(env) end)
        runner.assert_eq(true, ok)
        runner.assert_eq(2, updates)
        runner.assert_eq(1, unloads)
        runner.assert_eq(1, #env.manager._failure_records)
        runner.assert_eq("disabled", env.manager._mods[1].state)
        runner.assert_eq("running", env.manager._mods[2].state)
        runner.assert_not_nil(contains(env.logs, "<traceback unavailable>"))
        runner.assert_eq(1, count_contains(env.logs, "cleanup boom"))
    end)

    runner.register("hardening: dmf init escape stops load, labels collateral states, and cleans in reverse", function()
        local env = setup()
        local sequence = {}
        env.state.order = { "prior", "dmf", "later" }
        env.state.mods = {
            prior = descriptor({
                init = function() sequence[#sequence + 1] = "prior:init" end,
                on_unload = function() sequence[#sequence + 1] = "prior:unload" end,
            }),
            dmf = descriptor({
                init = function() sequence[#sequence + 1] = "dmf:init"; error("framework escape") end,
                on_unload = function() sequence[#sequence + 1] = "dmf:unload" end,
            }),
            later = descriptor({ init = function() sequence[#sequence + 1] = "later:init" end }),
        }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq({ "prior:init", "dmf:init", "dmf:unload", "prior:unload" }, sequence)
        runner.assert_eq("stopped", env.manager._mods[1].state)
        runner.assert_eq("disabled", env.manager._mods[2].state)
        runner.assert_eq("skipped", env.manager._mods[3].state)
        runner.assert_eq(true, env.manager._generation_failed)
        runner.assert_eq("done", env.manager._state)
        runner.assert_eq(1, env.retire_count())
        runner.assert_nil(contains(env.logs, "inner mod"))
    end)

    runner.register("hardening: dmf update escape stops fan-out and reverse-unloads every loaded outer object", function()
        -- Staged pass: prior loads on its own update (first update fires there);
        -- on dmf's load update the fan-out drives prior again, then dmf's update
        -- raises -> framework stop. "later" was never loaded by then, so it is
        -- skipped at the finalize update (no object, no unload); the loaded
        -- outers are reverse-unloaded exactly once.
        local env = setup()
        local sequence = {}
        local function object(name, fail)
            return {
                update = function()
                    sequence[#sequence + 1] = name .. ":update"
                    if fail then error("boundary boom") end
                end,
                on_unload = function() sequence[#sequence + 1] = name .. ":unload" end,
            }
        end
        env.state.order = { "prior", "dmf", "later" }
        env.state.mods = {
            prior = descriptor(object("prior", false)),
            dmf = descriptor(object("dmf", true)),
            later = descriptor(object("later", false)),
        }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq({
            "prior:update", "prior:update", "dmf:update",
            "dmf:unload", "prior:unload",
        }, sequence)
        runner.assert_eq("stopped", env.manager._mods[1].state)
        runner.assert_eq("disabled", env.manager._mods[2].state)
        runner.assert_eq("skipped", env.manager._mods[3].state,
            "later was never loaded; the stopped pass skips it at finalize")
        env.manager:update(1)
        runner.assert_eq(5, #sequence, "no outer callback repeats while generation is stopped")
    end)

    runner.register("hardening: DMF-driven and load-contract failures never trip lifecycle failure state", function()
        local env = setup()
        env.state.order = { "nilmod", "scalar", "throws", "good" }
        env.state.mods = {
            nilmod = descriptor(nil),
            scalar = descriptor(1),
            throws = { run = function() error("load failure") end },
            good = descriptor({ update = function() end }),
        }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq("dmf_driven", env.manager._mods[1].state)
        runner.assert_eq("failed", env.manager._mods[2].state)
        runner.assert_eq("failed", env.manager._mods[3].state)
        runner.assert_eq("running", env.manager._mods[4].state)
        runner.assert_eq(false, env.manager._generation_failed)
        runner.assert_eq(0, #env.manager._failure_records)
    end)

    runner.register("hardening: an error contained inside the dmf outer callback remains outside Relay policy", function()
        local env = setup()
        local contained = 0
        env.state.order = { "dmf" }
        env.state.mods = {
            dmf = descriptor({
                update = function()
                    local ok = pcall(function() error("simulated inner error") end)
                    if not ok then contained = contained + 1 end
                end,
            }),
        }
        env.manager:_scan_mods()
        update_to_done(env)
        env.manager:update(0.1)
        runner.assert_eq(2, contained)
        runner.assert_eq(false, env.manager._generation_failed)
        runner.assert_eq("running", env.manager._mods[1].state)
        runner.assert_eq(0, #env.manager._failure_records)
    end)

    runner.register("hardening: alerts use exact engine shape and immediate/15s/state-enter cadence", function()
        local env = setup()
        env.state.order = { "bad" }
        env.state.mods = { bad = descriptor({ update = function() error("boom") end }) }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq(1, #env.alerts)
        runner.assert_eq("event_add_notification_message", env.alerts[1].event_name)
        runner.assert_eq("alert", env.alerts[1].message_type)
        runner.assert_type("table", env.alerts[1].data)
        runner.assert_not_nil(env.alerts[1].data.text:find("disabled mod 'bad'", 1, true))

        env.manager:update(15)
        runner.assert_eq(2, #env.alerts, "15 seconds of manager time makes one reminder due")
        env.manager:update(1.9)
        env.manager:on_game_state_changed("enter", "StateGame", {})
        runner.assert_eq(2, #env.alerts, "state enter is deduped inside two seconds")
        env.manager:update(0.2)
        env.manager:on_game_state_changed("enter", "StateGame", {})
        runner.assert_eq(3, #env.alerts, "later state enter becomes reminder-eligible")
        runner.assert_not_nil(env.alerts[3].data.text:find("one or more mods", 1, true))
    end)

    runner.register("hardening: false developer mode requires restart and alert transport retries without spam", function()
        local env = setup({ developer_mode = false, event = false })
        env.state.order = { "bad" }
        env.state.mods = { bad = descriptor({ update = function() error("boom") end }) }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq(1, count_contains(env.logs, "alert transport unavailable"))
        env.manager:update(15)
        runner.assert_eq(1, count_contains(env.logs, "alert transport unavailable"))

        env.sb.Managers.event = {
            trigger = function(self, event_name, message_type, data)
                env.alerts[#env.alerts + 1] = { event_name = event_name, message_type = message_type, data = data }
            end,
        }
        env.manager:update(15)
        runner.assert_eq(1, #env.alerts)
        runner.assert_not_nil(env.alerts[1].data.text:find("Restart the game.", 1, true))
        runner.assert_nil(env.alerts[1].data.text:find("hot reload", 1, true))
    end)

    runner.register("hardening: framework reminder takes precedence over standalone failures", function()
        local env = setup()
        local sequence = {}
        env.state.order = { "standalone", "dmf", "later" }
        env.state.mods = {
            standalone = descriptor({
                update = function() sequence[#sequence + 1] = "standalone:update"; error("standalone") end,
                on_unload = function() sequence[#sequence + 1] = "standalone:unload" end,
            }),
            dmf = descriptor({
                update = function() sequence[#sequence + 1] = "dmf:update"; error("framework") end,
                on_unload = function() sequence[#sequence + 1] = "dmf:unload" end,
            }),
            later = descriptor({
                update = function() sequence[#sequence + 1] = "later:update" end,
                on_unload = function() sequence[#sequence + 1] = "later:unload" end,
            }),
        }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq(2, #env.alerts, "each newly latched failure gets an immediate attempt")
        -- Staged pass: standalone fails on its own load update and its deferred
        -- cleanup drains at that update's fan-out; dmf fails on the NEXT update
        -- (framework stop). "later" was never loaded -> skipped, no unload.
        runner.assert_eq({
            "standalone:update", "standalone:unload",
            "dmf:update", "dmf:unload",
        }, sequence, "each loaded outer unloads exactly once (reverse at each stop)")
        env.manager:update(15)
        runner.assert_eq(4, #sequence, "same-fan-out cleanup remains exactly once")
        runner.assert_eq(3, #env.alerts)
        runner.assert_not_nil(env.alerts[3].data.text:find("framework-boundary", 1, true))
        runner.assert_nil(env.alerts[3].data.text:find("one or more mods", 1, true))
    end)

    runner.register("hardening: post-load fan-out stop merges pending standalone cleanup into reverse order", function()
        -- The _rebuild_framework_cleanup_queue merge branch: a standalone
        -- failure claims cleanup mid-fan-out (object cleared, cleanup queued
        -- but not yet drained), then a framework failure in the SAME fan-out
        -- rebuilds the queue reverse — the claimed-not-done standalone must
        -- land AFTER the framework entry. Under staged loading the load pass
        -- drains every update, so this branch only fires post-pass now.
        local env = setup()
        local sequence = {}
        local fail = { prior = false, dmf = false }
        local function object(name)
            return {
                update = function()
                    sequence[#sequence + 1] = name .. ":update"
                    if fail[name] then error(name .. " boom") end
                end,
                on_unload = function() sequence[#sequence + 1] = name .. ":unload" end,
            }
        end
        env.state.order = { "prior", "mid", "dmf" }
        env.state.mods = {
            prior = descriptor(object("prior")),
            mid = descriptor(object("mid")),
            dmf = descriptor(object("dmf")),
        }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq("done", env.manager._state)
        for i = #sequence, 1, -1 do sequence[i] = nil end  -- drop load-pass updates

        -- ONE fan-out, two failures: prior's standalone first (cleanup claimed,
        -- deferred), dmf's framework failure second (stop + reverse rebuild).
        fail.prior = true
        fail.dmf = true
        env.manager:update(0.1)

        runner.assert_eq({
            "prior:update", "mid:update", "dmf:update",
            "dmf:unload", "mid:unload", "prior:unload",
        }, sequence, "the merged prior unload lands after dmf's (reverse rebuild)")
        runner.assert_eq("disabled", env.manager._mods[1].state)
        runner.assert_eq("stopped", env.manager._mods[2].state)
        runner.assert_eq("disabled", env.manager._mods[3].state)
        runner.assert_eq(2, #env.manager._failure_records)
        env.manager:update(1)
        runner.assert_eq(6, #sequence, "exactly-once unloads; no repeats while stopped")
    end)

    runner.register("hardening: framework-stopped generation hot reloads cleanly and clears old notices", function()
        local env = setup()
        env.state.order = { "dmf" }
        env.state.mods = { dmf = descriptor({ update = function() error("framework") end }) }
        env.manager:_scan_mods()
        update_to_done(env)
        runner.assert_eq(true, env.manager._generation_failed)
        runner.assert_eq("done", env.manager._state)

        local healthy_updates = 0
        env.state.mods = { dmf = descriptor({ update = function() healthy_updates = healthy_updates + 1 end }) }
        runner.assert_eq(true, env.manager:request_reload("test"))
        reload_to_done(env)
        runner.assert_eq(2, env.manager._generation)
        runner.assert_eq(false, env.manager._generation_failed)
        runner.assert_eq(0, #env.manager._failure_records)
        runner.assert_eq(1, healthy_updates)
        local alert_count = #env.alerts
        env.manager:update(30)
        runner.assert_eq(alert_count, #env.alerts, "old reminders stop after completed replacement")
    end)

    runner.register("hardening: replacement failure is generation-scoped and destroy cannot double-unload", function()
        local env = setup()
        local unloads = 0
        env.state.order = { "alpha" }
        env.state.mods = { alpha = descriptor({ on_unload = function() unloads = unloads + 1 end }) }
        env.manager:_scan_mods()
        update_to_done(env)

        env.state.mods = { alpha = descriptor({
            update = function() error("replacement boom") end,
            on_unload = function() unloads = unloads + 1 end,
        }) }
        env.manager:request_reload("test")
        reload_to_done(env)
        runner.assert_eq(2, env.manager._generation)
        runner.assert_eq(1, #env.manager._failure_records)
        runner.assert_eq(2, env.manager._failure_records[1].generation)
        runner.assert_eq("disabled", env.manager._mods[1].state)
        runner.assert_eq(2, unloads, "old and failed replacement objects each unload once")
        env.manager:destroy()
        runner.assert_eq(2, unloads, "destroy does not unload the disabled object twice")
    end)

    runner.register("hardening: destroy drains a claimed pending cleanup exactly once", function()
        local env = setup()
        local unloads = 0
        local object = { on_unload = function() unloads = unloads + 1 end }
        env.state.order = { "alpha" }
        env.state.mods = { alpha = descriptor(object) }
        env.manager:_scan_mods()
        update_to_done(env)
        local entry = env.manager._mods[1]
        env.manager:_handle_lifecycle_failure(entry, object, "update", "synthetic detail")
        env.manager:destroy()
        runner.assert_eq(1, unloads)
        env.manager:destroy()
        runner.assert_eq(1, unloads)
    end)
end
