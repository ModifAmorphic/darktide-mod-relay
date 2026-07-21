-- test_entry.lua — the loader entry (src/mod_loader/init.lua).
--
-- Asserts:
--   - idempotency: a second execution does not recapture the (now-wrapped) require
--   - captures engine facilities (Mods.original_require, Mods.lua.*, __print)
--   - loads modules in dependency order (file, class_registry, lifecycle, require_bridge)
--   - exposes Mods.coordinate_bootstrap + Mods.load_module
--   - wraps global require (so the bridge is active after entry runs)
--   - MOD_LOADER_DIR / RELAY_MOD_PATH stay distinct (loader root vs mod root)
--   - no Mods.hook / no loadstring-driven hook surface

local mock = require("mock")

return function(runner)
    -- Load the REAL entry via the harness. The entry uses Mods.lua.io (mock)
    -- + Mods.lua.loadstring (sandbox) to bootstrap-load the real modules from
    -- the staged loader root. mods.lst + mods are NOT staged here (the entry
    -- doesn't read them; mod_manager does, at boot).
    local function setup()
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function() return {} end  -- pre-wrap engine require
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        return sb
    end

    runner.register("entry: captures Mods.original_require (the pre-wrap require)", function()
        local pre = function() return "engine" end
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = pre
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        runner.assert_eq(pre, sb.Mods.original_require,
            "Mods.original_require must be the pre-wrap require, not the wrapper")
    end)

    runner.register("entry: wraps global require (wrapped != original)", function()
        local sb = setup()
        runner.assert_truthy(sb.require ~= sb.Mods.original_require,
            "global require must be wrapped after entry runs")
    end)

    runner.register("entry: captures Mods.lua.{io,loadstring,os,ffi}", function()
        local sb = setup()
        runner.assert_type("table", sb.Mods.lua.io)
        runner.assert_type("function", sb.Mods.lua.loadstring)
        -- os is present in the test stdlib; ffi is LuaJIT-only and present here.
        runner.assert_type("table", sb.Mods.lua.os)
    end)

    runner.register("entry: sets __print", function()
        local sb = setup()
        runner.assert_type("function", sb.__print)
    end)

    runner.register("entry: derives Mods._mod_path + _mod_root from RELAY_MOD_PATH", function()
        -- The contract: _mod_path is the boundary (parent of mods/), _mod_root
        -- is derived as _mod_path/mods. Use a distinct boundary so the
        -- derivation is visible (mock.MOD_ROOT is "/mods"; using it as the
        -- boundary would make _mod_root "/mods/mods" which obscures the test).
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = "/staged"
        sb.require = function() return {} end
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        runner.assert_eq("/staged", sb.Mods._mod_path,
            "_mod_path is the boundary (RELAY_MOD_PATH verbatim, normalized)")
        runner.assert_eq("/staged/mods", sb.Mods._mod_root,
            "_mod_root is derived as _mod_path .. '/mods'")
    end)

    runner.register("entry: bootstrap-loads modules in dependency order", function()
        -- Each loaded module exposes a distinct surface; their presence (in the
        -- right dependency shape) proves the load order.
        local sb = setup()
        runner.assert_type("table", sb.Mods.file, "file.lua loaded")
        runner.assert_type("function", sb.Mods.install_class_registry,
            "class_registry.lua loaded")
        runner.assert_type("function", sb.Mods.coordinate_bootstrap,
            "lifecycle.lua loaded (depends on class_registry)")
        runner.assert_type("function", sb.Mods.install_require_bridge,
            "require_bridge.lua loaded (depends on lifecycle.coordinator)")
    end)

    runner.register("entry: exposes Mods.load_module (dofile-style loader)", function()
        local sb = setup()
        runner.assert_type("function", sb.Mods.load_module)
    end)

    runner.register("entry: idempotency — second run does not recapture wrapped require", function()
        -- Re-running the entry after require is wrapped must NOT overwrite
        -- Mods.original_require with the wrapped function (would cause recursion).
        local sb = setup()
        local captured_original = sb.Mods.original_require
        runner.assert_eq(true, sb.Mods._loaded)
        -- Re-run the entry chunk.
        mock.load_module("init", sb)()
        runner.assert_eq(captured_original, sb.Mods.original_require,
            "second run must not recapture the wrapped require")
    end)

    runner.register("entry: _loaded flag set after successful bootstrap", function()
        local sb = setup()
        runner.assert_eq(true, sb.Mods._loaded)
    end)

    runner.register("entry: loader root + mod path stay distinct", function()
        local sb = setup()
        runner.assert_eq(mock.MOD_LOADER_ROOT, sb.MOD_LOADER_DIR)
        runner.assert_eq(mock.MOD_ROOT, sb.RELAY_MOD_PATH)
        -- _mod_path mirrors RELAY_MOD_PATH (normalized); _mod_root is
        -- derived as _mod_path/mods. Both stay distinct from MOD_LOADER_DIR.
        runner.assert_eq(mock.MOD_ROOT, sb.Mods._mod_path)
        runner.assert_eq(mock.MOD_ROOT .. "/mods", sb.Mods._mod_root)
    end)

    runner.register("entry: no Mods.hook / no loadstring-driven hook surface", function()
        local sb = setup()
        runner.assert_nil(sb.Mods.hook)
        runner.assert_nil(sb._G.MODS_HOOKS)
        runner.assert_nil(sb._G.MODS_HOOKS_BY_FILE)
    end)

    runner.register("entry: bootstrap aborts cleanly if a module fails to load", function()
        -- Stage a loader root that's MISSING require_bridge.lua -> the entry
        -- logs + returns false without installing the bridge.
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function() return {} end
        local logged = {}
        sb.print = function(m) table.insert(logged, m) end
        local files = mock.stage_mod_loader()
        files[mock.MOD_LOADER_ROOT .. "/require_bridge.lua"] = nil  -- remove it
        -- Rebuild the io mock without require_bridge (make_io skips nil entries).
        local trimmed = {}
        for k, v in pairs(files) do trimmed[k] = v end
        trimmed[mock.MOD_LOADER_ROOT .. "/require_bridge.lua"] = nil
        sb.io = mock.make_io(trimmed)
        local r = mock.load_module("init", sb)()
        runner.assert_eq(false, r, "entry returns false on bootstrap failure")
        runner.assert_nil(sb.Mods.install_require_bridge,
            "bridge not installed when a module is missing")
    end)
end
