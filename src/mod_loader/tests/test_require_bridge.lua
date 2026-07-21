-- test_require_bridge.lua — require wrap + require store (src/mod_loader/require_bridge.lua).
--
-- Asserts:
--   - wraps global require idempotently; Mods.original_require retained
--   - table results appended to Mods.require_store[path] by identity dedup
--     (non-consecutive reappearance of the same table does not duplicate)
--   - non-table results are not cached
--   - varargs forwarded; result returned
--   - the lifecycle bootstrap coordinator is called after every successful require
--   - no Mods.hook, no file-hook replay

local mock = require("mock")

return function(runner)
    -- Load require_bridge into a sandbox with Mods.original_require set to a
    -- fake. Returns the sandbox + a coordinator-call counter (a getter, since
    -- Lua numbers are by-value and the spy increments an upvalue).
    local function setup(fake_require)
        local sb = mock.new_sandbox()
        sb.Mods = {
            original_require = fake_require or function(path) return {} end,
            require_store = {},
        }
        local coord_calls = 0
        sb.Mods.coordinate_bootstrap = function() coord_calls = coord_calls + 1 end
        sb.__print = function() end
        mock.run_module("require_bridge", sb)
        sb.Mods.install_require_bridge()
        return sb, function() return coord_calls end
    end

    runner.register("require_bridge: install wraps global require idempotently", function()
        local sb, _ = setup(function() return {} end)
        runner.assert_type("function", sb.require)
        local first = sb.require
        runner.assert_eq(true, sb.Mods.install_require_bridge(),
            "second install is a no-op returning true")
        runner.assert_eq(first, sb.require, "global require must not be re-wrapped")
    end)

    runner.register("require_bridge: Mods.original_require is retained (the pre-wrap engine require)", function()
        local engine = function() return {} end
        local sb, _ = setup(engine)
        runner.assert_eq(engine, sb.Mods.original_require,
            "original require must be retained verbatim")
    end)

    runner.register("require_bridge: table result is appended to require_store[path]", function()
        local t = { a = 1 }
        local sb, _ = setup(function() return t end)
        sb.require("some/path")
        runner.assert_eq(1, #sb.Mods.require_store["some/path"])
        runner.assert_eq(t, sb.Mods.require_store["some/path"][1])
    end)

    runner.register("require_bridge: distinct tables for the same path each get recorded", function()
        local queue = { { 1 }, { 2 } }
        local sb, _ = setup(function() return table.remove(queue, 1) end)
        sb.require("p")
        sb.require("p")
        runner.assert_eq(2, #sb.Mods.require_store["p"],
            "two distinct table identities -> two entries")
    end)

    runner.register("require_bridge: identity dedup — same table reappearing non-consecutively is NOT duplicated", function()
        -- The same table T appears for path "p", then a DIFFERENT table appears
        -- for "p", then T appears again. T must be recorded ONCE (the third
        -- require is a re-appearance of an already-recorded identity).
        local T = { name = "T" }
        local U = { name = "U" }
        local queue = { T, U, T }
        local sb, _ = setup(function() return table.remove(queue, 1) end)
        sb.require("p")  -- T
        sb.require("p")  -- U
        sb.require("p")  -- T again (non-consecutive re-appearance)
        runner.assert_eq(2, #sb.Mods.require_store["p"],
            "T must not be recorded twice despite non-consecutive re-appearance")
        runner.assert_eq(T, sb.Mods.require_store["p"][1])
        runner.assert_eq(U, sb.Mods.require_store["p"][2])
    end)

    runner.register("require_bridge: identity dedup — consecutive same table is also not duplicated", function()
        local T = {}
        local queue = { T, T }
        local sb, _ = setup(function() return table.remove(queue, 1) end)
        sb.require("p")
        sb.require("p")
        runner.assert_eq(1, #sb.Mods.require_store["p"])
    end)

    runner.register("require_bridge: non-table results are not cached in the store", function()
        local sb, _ = setup(function() return 42 end)
        sb.require("num")
        sb.require("num")
        runner.assert_nil(sb.Mods.require_store["num"],
            "non-table (number) results must not be cached")
    end)

    runner.register("require_bridge: nil results are not cached", function()
        local sb, _ = setup(function() return nil end)
        sb.require("nothing")
        runner.assert_nil(sb.Mods.require_store["nothing"])
    end)

    runner.register("require_bridge: requires of different paths get separate store lists", function()
        local a, b = { 1 }, { 2 }
        local queue = { a, b }
        local sb, _ = setup(function() return table.remove(queue, 1) end)
        sb.require("a")
        sb.require("b")
        runner.assert_eq(1, #sb.Mods.require_store["a"])
        runner.assert_eq(1, #sb.Mods.require_store["b"])
    end)

    runner.register("require_bridge: forwards varargs to the original require", function()
        local received
        local sb, _ = setup(function(path, ...)
            received = { path = path, extra = { ... } }
            return {}
        end)
        sb.require("p", "x", "y")
        runner.assert_eq("p", received.path)
        runner.assert_eq({ "x", "y" }, received.extra, "varargs must be forwarded")
    end)

    runner.register("require_bridge: returns the original require's result verbatim", function()
        local sentinel = { only = true }
        local sb, _ = setup(function() return sentinel end)
        runner.assert_eq(sentinel, sb.require("p"))
    end)

    runner.register("require_bridge: coordinator called after every successful require", function()
        local sb, coord = setup(function() return {} end)
        sb.require("p")
        sb.require("p")
        sb.require("q")
        runner.assert_eq(3, coord(),
            "coordinator must be called once per successful require")
    end)

    runner.register("require_bridge: no Mods.hook / no file-hook replay surface", function()
        local sb, _ = setup(function() return {} end)
        runner.assert_nil(sb.Mods.hook, "no Mods.hook table")
        runner.assert_nil(sb.Mods.enable_by_file, "no enable_by_file (no file-hook replay)")
        runner.assert_nil(sb._G.MODS_HOOKS, "no MODS_HOOKS global")
        runner.assert_nil(sb._G.MODS_HOOKS_BY_FILE, "no MODS_HOOKS_BY_FILE global")
    end)
end
