-- test_negative.lua — cross-cutting negative assertions for the whole loader.
--
-- These pin the "what we are NOT" contract: no loadstring-driven hook
-- subsystem, no loadstring-generated hook chains, no legacy globals, and the
-- unresolved-class sentinel never writes _G (it is a read-side concern only —
-- registered classes ARE globalized to _G[name] for the community contract; see
-- test_class_registry for that positive behavior). They load the real entry
-- (so every module is wired as in production) and assert the absence of the
-- old surface.

local mock = require("mock")

return function(runner)
    -- Load the real entry + all modules, then assert the negative contract.
    local function setup()
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function() return {} end
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        return sb
    end

    -- ---------------------------------------------------------------------
    -- No loadstring-driven hook subsystem
    -- ---------------------------------------------------------------------

    runner.register("negative: no Mods.hook table", function()
        local sb = setup()
        runner.assert_nil(sb.Mods.hook)
    end)

    runner.register("negative: no MODS_HOOKS global", function()
        local sb = setup()
        runner.assert_nil(sb._G.MODS_HOOKS)
    end)

    runner.register("negative: no MODS_HOOKS_BY_FILE global", function()
        local sb = setup()
        runner.assert_nil(sb._G.MODS_HOOKS_BY_FILE)
    end)

    runner.register("negative: no _deferred_hooks / no install_lifecycle_hooks", function()
        local sb = setup()
        runner.assert_nil(sb.Mods._deferred_hooks)
        runner.assert_nil(sb.Mods.install_lifecycle_hooks)
    end)

    runner.register("negative: no enable_by_file / set_on_file file-hook replay", function()
        local sb = setup()
        runner.assert_nil(sb.Mods.enable_by_file)
        runner.assert_nil(sb.Mods.set_on_file)
        runner.assert_nil(sb.Mods.file.enable_by_file)
    end)

    -- ---------------------------------------------------------------------
    -- CLASS unresolved-class sentinel (NOT plain; missing keys return the name)
    -- ---------------------------------------------------------------------
    --
    -- CLASS is NOT a plain table: missing keys return the unresolved name as a
    -- string sentinel (official DMF compat — generic_hook accepts string/table).
    -- rawget still returns nil (metatable bypassed) so lifecycle readiness
    -- treats unresolved classes as absent. The sentinel is a READ-side concern
    -- only — it never writes _G. (Registered classes ARE globalized to _G for
    -- the community contract; that positive behavior is asserted in
    -- test_class_registry, not here.)

    runner.register("negative: unresolved CLASS key returns the name string (sentinel, not nil)", function()
        local sb = setup()
        sb.class = function(name) return { name = name } end
        sb.Mods.coordinate_bootstrap()
        local _ = sb.class("Real")  -- registers CLASS.Real
        runner.assert_not_nil(sb.CLASS.Real)
        -- Missing keys return the sentinel string, NOT nil.
        runner.assert_eq("DoesNotExist", sb.CLASS.DoesNotExist,
            "unresolved CLASS key returns the name string sentinel")
        runner.assert_eq("Dotted.Name", sb.CLASS["Dotted.Name"])
        -- rawget bypasses the metatable -> nil (lifecycle readiness).
        runner.assert_nil(rawget(sb.CLASS, "DoesNotExist"),
            "rawget must return nil for unresolved classes")
        -- The sentinel is read-only: it must NOT have created a _G entry.
        runner.assert_nil(sb._G.DoesNotExist,
            "the unresolved-class sentinel must not create a _G entry")
    end)

    -- ---------------------------------------------------------------------
    -- No loadstring-driven hook chains
    -- ---------------------------------------------------------------------

    runner.register("negative: no loadstring-driven hook-chain modules loaded", function()
        local sb = setup()
        runner.assert_nil(sb.Mods.hook)
        runner.assert_nil(sb._G.MODS_HOOKS)
        -- The old modules (hook.lua, class_patch.lua, require_wrap.lua) must
        -- not leave their internal tables behind.
        runner.assert_nil(sb._G.MODS_HOOKS_BY_FILE)
    end)
end
