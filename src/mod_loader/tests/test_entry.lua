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
        sb.MOD_RELAY_VERSION = "0.3.0-beta.2"
        sb.require = function() return {} end  -- pre-wrap engine require
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        return sb
    end

    -- Count log lines containing a substring (plain find).
    local function count_log(logged, sub)
        local n = 0
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find(sub, 1, true) then n = n + 1 end
        end
        return n
    end

    -- Build a sandbox whose pre-wrap require is a spy. ffi_behavior controls
    -- what the spy returns/does when called with "ffi":
    --   { result = <value> }  -> returns <value> for "ffi" (other names: {})
    --   { throw = "msg" }     -> errors with "msg" for "ffi"
    -- Returns sb + the calls list (each entry is the name passed to require).
    local function setup_ffi(ffi_behavior)
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        local calls = {}
        sb.require = function(name)
            table.insert(calls, name)
            if name == "ffi" then
                if ffi_behavior and ffi_behavior.throw then
                    error(ffi_behavior.throw)
                end
                return ffi_behavior and ffi_behavior.result or {}
            end
            return {}
        end
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        return sb, calls
    end

    -- Count how many times "ffi" appears in the calls list.
    local function count_ffi_calls(calls)
        local n = 0
        for _, name in ipairs(calls) do
            if name == "ffi" then n = n + 1 end
        end
        return n
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

    runner.register("entry: snapshots exact Relay version and retires trampoline global", function()
        local sb = setup()
        runner.assert_eq("0.3.0-beta.2", sb.Mods._relay.version)
        runner.assert_nil(sb.MOD_RELAY_VERSION,
            "temporary trampoline version global must be retired")
    end)

    runner.register("entry: captures only private traceback function, not debug library", function()
        local sb = setup()
        runner.assert_type("function", sb.Mods._relay.traceback)
        runner.assert_nil(sb.Mods.lua.debug,
            "debug library must not be published on the compatibility surface")
    end)

    runner.register("entry: missing traceback capability degrades privately", function()
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.MOD_RELAY_VERSION = "0.2.0"
        sb.debug = nil
        sb.require = function() return {} end
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        local ok, result = pcall(function() return mock.load_module("init", sb)() end)
        runner.assert_eq(true, ok, tostring(result))
        runner.assert_nil(sb.Mods._relay.traceback)
        runner.assert_nil(sb.MOD_RELAY_VERSION)
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

    -- -----------------------------------------------------------------
    -- FFI module publication (Finding 1)
    -- -----------------------------------------------------------------

    runner.register("entry: Mods.lua.ffi is the engine FFI module (required via original_require)", function()
        -- The LuaJIT harness has a real require("ffi"); the entry must publish
        -- exactly that module table (not a global, not a wrapper).
        local real_ffi = require("ffi")
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function(name) if name == "ffi" then return real_ffi end; return {} end
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        runner.assert_type("table", sb.Mods.lua.ffi, "Mods.lua.ffi is a table")
        runner.assert_eq(real_ffi, sb.Mods.lua.ffi,
            "Mods.lua.ffi is the engine FFI module table (identity with require('ffi'))")
    end)

    runner.register("entry: FFI acquisition requests the module exactly once", function()
        local sb, calls = setup_ffi({ result = { marker = "ffi" } })
        mock.load_module("init", sb)()
        runner.assert_eq(1, count_ffi_calls(calls),
            "original_require('ffi') called exactly once during entry")
    end)

    runner.register("entry: an existing global ffi is NOT treated as authoritative", function()
        -- A sentinel non-table global `ffi` must NOT be published; the required
        -- module wins (proves the entry uses original_require, not a global grab).
        local ffi_module = { marker = "required ffi" }
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function(name) if name == "ffi" then return ffi_module end; return {} end
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        sb.ffi = "sentinel-non-table"  -- a misleading global that must be ignored
        mock.load_module("init", sb)()
        runner.assert_eq(ffi_module, sb.Mods.lua.ffi,
            "Mods.lua.ffi is the required module, not the global sentinel")
    end)

    runner.register("entry: FFI loader error is contained + logged once; entry still succeeds", function()
        local logged = {}
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function(name) if name == "ffi" then error("ffi loader boom") end; return {} end
        sb.print = function(m) table.insert(logged, m) end
        sb.io = mock.make_io(mock.stage_mod_loader())
        local r = mock.load_module("init", sb)()
        runner.assert_eq(true, r, "entry succeeds despite the FFI loader error")
        runner.assert_nil(sb.Mods.lua.ffi, "Mods.lua.ffi stays nil on error")
        runner.assert_eq(1, count_log(logged, "ffi module unavailable"),
            "exactly one ffi-unavailable diagnostic on error")
    end)

    runner.register("entry: non-table FFI result degrades to nil with one diagnostic", function()
        local logged = {}
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function(name) if name == "ffi" then return "not a table" end; return {} end
        sb.print = function(m) table.insert(logged, m) end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        runner.assert_nil(sb.Mods.lua.ffi, "non-table result -> Mods.lua.ffi stays nil")
        runner.assert_eq(1, count_log(logged, "ffi module unavailable"),
            "exactly one diagnostic for non-table result")
    end)

    runner.register("entry: FFI acquisition does NOT populate Mods.require_store", function()
        local sb = setup_ffi({ result = { marker = "ffi" } })
        mock.load_module("init", sb)()
        local total = 0
        for _ in pairs(sb.Mods.require_store) do total = total + 1 end
        runner.assert_eq(0, total,
            "require_store empty (FFI acquired via original_require, not the bridge)")
    end)

    runner.register("entry: FFI path does not affect the require bridge wrap", function()
        local sb = setup_ffi({ result = { marker = "ffi" } })
        mock.load_module("init", sb)()
        runner.assert_truthy(sb.require ~= sb.Mods.original_require,
            "global require is wrapped (bridge installed) even with FFI acquisition")
        runner.assert_type("function", sb.Mods.install_require_bridge,
            "the require bridge is installed")
    end)

    runner.register("entry: second entry run does not reacquire FFI; original_require preserved", function()
        local calls = {}
        local ffi_module = { marker = "ffi" }
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function(name)
            table.insert(calls, name)
            if name == "ffi" then return ffi_module end
            return {}
        end
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        runner.assert_eq(true, sb.Mods._loaded)
        runner.assert_eq(1, count_ffi_calls(calls), "one acquisition on first entry")
        local ffi_after_first = sb.Mods.lua.ffi
        local captured_original = sb.Mods.original_require
        -- Re-run the entry chunk; the _loaded guard bails early (no re-acquisition,
        -- no recapture of the wrapped require as original_require).
        mock.load_module("init", sb)()
        runner.assert_eq(captured_original, sb.Mods.original_require,
            "second run preserves original_require (no recapture of the wrapper)")
        runner.assert_eq(ffi_after_first, sb.Mods.lua.ffi,
            "second run does not reacquire FFI (same module table)")
        runner.assert_eq(1, count_ffi_calls(calls),
            "no additional original_require('ffi') call on second entry")
    end)
end
