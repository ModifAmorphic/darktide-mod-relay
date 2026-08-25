-- test_entry.lua — the loader entry (src/mod_loader/init.lua).
--
-- Asserts:
--   - idempotency: a second execution does not recapture the (now-wrapped) require
--   - captures engine facilities (Mods.original_require, Mods.lua.*, __print)
--   - loads modules in dependency order (file, class_registry, lifecycle, require_bridge)
--   - exposes Mods.coordinate_bootstrap + Mods.load_module
--   - wraps global require (so the bridge is active after entry runs)
--   - MOD_LOADER_DIR / RELAY_MOD_PATH stay distinct (loader root vs mod root)
--   - RELAY_MODS_IN_GAME_TREE snapshot (nil-safe; retired global; one
--     io-retargeting-disabled diagnostic when gated)
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
        -- The contract: _mod_path is the config (parent of mods/), _mod_root
        -- is derived as _mod_path/mods. Use a distinct config so the
        -- derivation is visible (mock.MOD_ROOT is "/mods"; using it as the
        -- config would make _mod_root "/mods/mods" which obscures the test).
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = "/staged"
        sb.require = function() return {} end
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        runner.assert_eq("/staged", sb.Mods._mod_path,
            "_mod_path is the config (RELAY_MOD_PATH verbatim, normalized)")
        runner.assert_eq("/staged/mods", sb.Mods._mod_root,
            "_mod_root is derived as _mod_path .. '/mods'")
    end)

    -- -----------------------------------------------------------------
    -- RELAY_MODS_IN_GAME_TREE snapshot (the launcher-derived io-retargeting
    -- gate; snapshotted beside skip_splash, BEFORE the module bootstrap loop
    -- so file.lua reads the field at module-load time)
    -- -----------------------------------------------------------------

    -- Run the REAL entry with a (possibly absent) baked
    -- RELAY_MODS_IN_GAME_TREE; returns (sb, logged) when a print spy is used.
    local function setup_game_tree(global_value)
        local logged = {}
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.MOD_RELAY_VERSION = "0.3.0-beta.2"
        if global_value ~= "absent" then
            sb.RELAY_MODS_IN_GAME_TREE = global_value
        end
        sb.require = function() return {} end
        sb.print = function(m) table.insert(logged, m) end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        return sb, logged
    end

    runner.register("entry: snapshots RELAY_MODS_IN_GAME_TREE \"1\" as true + retires the global", function()
        local sb = setup_game_tree("1")
        runner.assert_eq(true, sb.Mods._relay.mods_in_game_tree,
            "the \"1\" hint means the mod path IS the game dir (gate on)")
        runner.assert_nil(sb.RELAY_MODS_IN_GAME_TREE,
            "temporary trampoline global must be retired")
    end)

    runner.register("entry: snapshots RELAY_MODS_IN_GAME_TREE \"\" as false + retires the global", function()
        local sb = setup_game_tree("")
        runner.assert_eq(false, sb.Mods._relay.mods_in_game_tree,
            "the empty string means not in the game tree (gate off)")
        runner.assert_nil(sb.RELAY_MODS_IN_GAME_TREE)
    end)

    runner.register("entry: nil-safe when RELAY_MODS_IN_GAME_TREE is absent (older shell)", function()
        local sb = setup_game_tree("absent")
        runner.assert_eq(false, sb.Mods._relay.mods_in_game_tree,
            "an absent global must degrade to gate off")
        runner.assert_nil(sb.RELAY_MODS_IN_GAME_TREE)
        runner.assert_eq(true, sb.Mods._loaded,
            "the entry completes unchanged when the global is absent")
    end)

    runner.register("entry: game-tree gate logs exactly one io-retargeting-disabled diagnostic", function()
        local sb, logged = setup_game_tree("1")
        runner.assert_eq(1, count_log(logged, "mod path is the game dir; io retargeting disabled"),
            "gated + non-empty mod path emits the single INFO diagnostic")
        -- Gate off: no diagnostic.
        local sb2, logged2 = setup_game_tree("")
        runner.assert_eq(0, count_log(logged2, "io retargeting disabled"),
            "gate off must not log the diagnostic")
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
    -- FFI module publication
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

    -- -----------------------------------------------------------------
    -- Mods._relay leveled diagnostic logger (the shared loader print helper)
    -- -----------------------------------------------------------------
    --
    -- The helper init.lua publishes BEFORE the module-bootstrap loop. Every
    -- loader module reads its leveled prints from it. These tests exercise the
    -- REAL helper (not the mock.attach_logger test fake used by isolated module
    -- tests): format, totality over bad input, and the never-a-second-failure
    -- pcall guard.

    -- Run the entry with a print spy; return (sb, logged) with the spy list
    -- cleared of bootstrap-time captures so a test observes only its own calls.
    local function run_init_logged()
        local logged = {}
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function() return {} end
        sb.print = function(m) logged[#logged + 1] = m end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        for i = #logged, 1, -1 do logged[i] = nil end
        return sb, logged
    end

    runner.register("entry: publishes log_info/log_debug/log_warn/log_error on Mods._relay", function()
        local sb = run_init_logged()
        runner.assert_type("function", sb.Mods._relay.log_info)
        runner.assert_type("function", sb.Mods._relay.log_debug)
        runner.assert_type("function", sb.Mods._relay.log_warn)
        runner.assert_type("function", sb.Mods._relay.log_error)
    end)

    runner.register("entry: each log helper emits '{LEVEL} [mod_loader] {message}'", function()
        local sb, logged = run_init_logged()
        sb.Mods._relay.log_info("an info message")
        sb.Mods._relay.log_debug("a debug message")
        sb.Mods._relay.log_warn("a warn message")
        sb.Mods._relay.log_error("an error message")
        runner.assert_eq("INFO [mod_loader] an info message", logged[1])
        runner.assert_eq("DEBUG [mod_loader] a debug message", logged[2])
        runner.assert_eq("WARN [mod_loader] a warn message", logged[3])
        runner.assert_eq("ERROR [mod_loader] an error message", logged[4])
    end)

    runner.register("entry: log helpers are total over bad input (non-string / unprintable) and never error", function()
        local sb, logged = run_init_logged()
        -- nil / number / table all stringify without raising.
        local ok = pcall(function()
            sb.Mods._relay.log_info(nil)
            sb.Mods._relay.log_debug(42)
            sb.Mods._relay.log_warn({})
        end)
        runner.assert_eq(true, ok, "non-string messages must not raise")
        runner.assert_truthy(logged[1]:find("nil", 1, true) ~= nil, "nil renders as 'nil'")
        runner.assert_truthy(logged[2]:find("42", 1, true) ~= nil, "number renders textually")
        -- A value whose __tostring metamethod errors must yield the safe
        -- fallback, not propagate (safe_text is tostring-under-pcall).
        local unprintable = setmetatable({}, { __tostring = function() error("boom") end })
        local ok2 = pcall(sb.Mods._relay.log_error, unprintable)
        runner.assert_eq(true, ok2, "an unprintable value must not raise")
        runner.assert_eq("ERROR [mod_loader] <unprintable error>", logged[#logged],
            "unprintable message renders as the <unprintable error> fallback")
    end)

    runner.register("entry: a log helper swallows a failing print surface (never a second failure path)", function()
        -- If the underlying print errors, the helper must contain it: a
        -- diagnostic must never break loading. init's own bootstrap-time print
        -- is swallowed under this failing print too.
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.require = function() return {} end
        sb.print = function() error("print exploded", 0) end
        sb.io = mock.make_io(mock.stage_mod_loader())
        local r = mock.load_module("init", sb)()
        runner.assert_eq(true, r, "entry still succeeds when the print surface errors")
        local ok = pcall(sb.Mods._relay.log_info, "anything")
        runner.assert_eq(true, ok, "log_info must not propagate a print-surface error")
    end)

    -- -----------------------------------------------------------------
    -- Trace diagnostics: the source-gated log_trace helper + frame_stamp
    -- -----------------------------------------------------------------

    -- Run the REAL entry with a (possibly absent) trampoline-baked
    -- RELAY_LOG_LEVEL global — the trace gate's config seam, same pattern as
    -- the other baked globals (see the RELAY_SKIP_SPLASH /
    -- RELAY_MODS_IN_GAME_TREE tests above). Returns (sb, logged) with
    -- bootstrap-time captures cleared.
    local function run_init_trace(baked_level)
        local logged = {}
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        if baked_level ~= nil then
            sb.RELAY_LOG_LEVEL = baked_level
        end
        sb.require = function() return {} end
        sb.print = function(m) logged[#logged + 1] = m end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        for i = #logged, 1, -1 do logged[i] = nil end
        return sb, logged
    end

    runner.register("entry: publishes log_trace + frame_stamp + _update_bump on Mods._relay", function()
        local sb = run_init_trace(nil)
        runner.assert_type("function", sb.Mods._relay.log_trace)
        runner.assert_type("function", sb.Mods._relay.frame_stamp)
        runner.assert_type("function", sb.Mods._relay._update_bump)
        runner.assert_eq(0, sb.Mods._relay._update,
            "the update counter starts at 0 (injection epoch)")
        runner.assert_eq(false, sb.Mods._relay._trace_enabled,
            "no baked RELAY_LOG_LEVEL -> the private trace flag is false")
        runner.assert_nil(sb.RELAY_LOG_LEVEL,
            "the trampoline global must be retired (absent case)")
    end)

    runner.register("entry: log_trace is a no-op unless the gate is on (level filtering stays the shell's job)", function()
        -- Off by default with the global absent.
        local sb, logged = run_init_trace(nil)
        sb.Mods._relay.log_trace("a trace message")
        sb.Mods._relay.log_trace(42)
        runner.assert_eq(0, #logged, "no baked global: log_trace prints nothing")
        -- A baked non-trace level is NOT trace.
        local sb2, logged2 = run_init_trace("debug")
        sb2.Mods._relay.log_trace("a trace message")
        runner.assert_eq(0, #logged2, "'debug' does not enable trace")
        runner.assert_eq(false, sb2.Mods._relay._trace_enabled)
        runner.assert_nil(sb2.RELAY_LOG_LEVEL, "the trampoline global must be retired")
        -- The empty-string baked form (the C unset representation) is off too.
        local sb3, logged3 = run_init_trace("")
        sb3.Mods._relay.log_trace("a trace message")
        runner.assert_eq(0, #logged3, "the empty-string baked form means unset -> off")
        runner.assert_eq(false, sb3.Mods._relay._trace_enabled)
        runner.assert_nil(sb3.RELAY_LOG_LEVEL)
    end)

    runner.register("entry: trace gate is case-insensitive ('trace' / 'TRACE') and stamps every line", function()
        for _, value in ipairs({ "trace", "TRACE", "Trace" }) do
            local sb, logged = run_init_trace(value)
            runner.assert_eq(true, sb.Mods._relay._trace_enabled,
                "'" .. value .. "' enables trace (case-insensitive, like the shell)")
            runner.assert_nil(sb.RELAY_LOG_LEVEL,
                "the trampoline global must be retired (enabled case)")
            sb.Mods._relay.log_trace("a trace message")
            runner.assert_eq(1, #logged, "exactly one line for one call")
            runner.assert_eq("TRACE [mod_loader] a trace message update=0 frame=?", logged[1],
                "TRACE follows the community prefix shape + appends the combined update/frame stamp")
        end
    end)

    runner.register("entry: log_trace is total over bad input (safe_text) and never errors", function()
        local sb = run_init_trace("trace")
        local unprintable = setmetatable({}, { __tostring = function() error("boom") end })
        local ok = pcall(function()
            sb.Mods._relay.log_trace(nil)
            sb.Mods._relay.log_trace(42)
            sb.Mods._relay.log_trace({})
            sb.Mods._relay.log_trace(unprintable)
        end)
        runner.assert_eq(true, ok, "non-string/unprintable messages must not raise")
    end)

    runner.register("entry: frame_stamp formats 'update=N frame=M' (update primary, frame secondary)", function()
        local sb = run_init_trace(nil)
        -- Pre-main.lua moment: FRAME_INDEX does not exist yet; update 0 = injection.
        runner.assert_eq(" update=0 frame=?", sb.Mods._relay.frame_stamp(),
            "no FRAME_INDEX yet (pre-main.lua) -> update=0, frame '?'")
        sb.FRAME_INDEX = -1  -- scripts/main.lua initializes it to -1 at load
        runner.assert_eq(" update=0 frame=-1", sb.Mods._relay.frame_stamp(),
            "pre-first-update: update still 0, the initial -1 renders")
        -- Per engine update: update +1 (observed boundaries), FRAME_INDEX +1.
        sb.Mods._relay._update_bump()
        sb.FRAME_INDEX = 0
        runner.assert_eq(" update=1 frame=0", sb.Mods._relay.frame_stamp(),
            "during/after the first observed update: update=1 frame=0")
        sb.Mods._relay._update_bump()
        sb.FRAME_INDEX = 1
        runner.assert_eq(" update=2 frame=1", sb.Mods._relay.frame_stamp())
        sb.Mods._relay._update_bump()
        sb.FRAME_INDEX = 12345
        runner.assert_eq(" update=3 frame=12345", sb.Mods._relay.frame_stamp())
        -- A non-number FRAME_INDEX degrades only the frame field.
        sb.FRAME_INDEX = "not a number"
        runner.assert_eq(" update=3 frame=?", sb.Mods._relay.frame_stamp(),
            "a non-number FRAME_INDEX degrades to '?' (update unaffected)")
        -- Contract shape: leading space, update first (non-negative digits),
        -- frame second (optional minus, digits, or '?').
        sb.FRAME_INDEX = 7
        local stamp = sb.Mods._relay.frame_stamp()
        runner.assert_truthy(stamp:find("^ update=%d+ frame=%-?%d+$") ~= nil,
            "numeric stamps match '^ update=%d+ frame=%-?%d+$'")
    end)

    runner.register("entry: frame_stamp leads with 'stage=S' while a stage epoch is published", function()
        -- mod_manager owns the epoch (set at a pass's first load attempt,
        -- cleared at every pass end); this pins the STAMP side against the
        -- real helper: stage leads, then update, then frame; computed
        -- (update - epoch), 0-based; absent entirely with no epoch.
        local sb = run_init_trace(nil)
        sb.FRAME_INDEX = 5
        sb.Mods._relay._update = 36
        runner.assert_eq(" update=36 frame=5", sb.Mods._relay.frame_stamp(),
            "no epoch published -> no stage field")
        sb.Mods._relay._stage_epoch = 36
        runner.assert_eq(" stage=0 update=36 frame=5", sb.Mods._relay.frame_stamp(),
            "epoch == current update -> stage=0 (the first loading update)")
        sb.Mods._relay._update_bump()
        sb.FRAME_INDEX = 6
        runner.assert_eq(" stage=1 update=37 frame=6", sb.Mods._relay.frame_stamp(),
            "one update later -> stage=1 (same-update lines share a stage)")
        sb.Mods._relay._update_bump()
        sb.Mods._relay._update_bump()
        runner.assert_eq(" stage=3 update=39 frame=6", sb.Mods._relay.frame_stamp(),
            "stage tracks the counter (epoch untouched)")
        -- Clearing the epoch removes the field again (the pass ended).
        sb.Mods._relay._stage_epoch = nil
        runner.assert_eq(" update=39 frame=6", sb.Mods._relay.frame_stamp(),
            "epoch cleared -> the stamp is unstaged again")
        -- Total over corrupted state: a non-number epoch is ignored; a
        -- corrupted counter with a live epoch clamps the rendered values.
        sb.Mods._relay._stage_epoch = "bogus"
        runner.assert_eq(" update=39 frame=6", sb.Mods._relay.frame_stamp(),
            "a non-number epoch means no stage (never throws)")
        sb.Mods._relay._stage_epoch = 38
        sb.Mods._relay._update = {}
        local ok, stamp = pcall(sb.Mods._relay.frame_stamp)
        runner.assert_eq(true, ok, "frame_stamp must never throw")
        runner.assert_eq(" stage=0 update=0 frame=6", stamp,
            "a corrupted counter renders update=0 and stage clamps to 0")
    end)

    runner.register("entry: _update_bump increments monotonically and is total over corrupted state", function()
        local sb = run_init_trace(nil)
        for i = 1, 3 do
            sb.Mods._relay._update_bump()
            runner.assert_eq(i, sb.Mods._relay._update)
        end
        -- A corrupted counter (non-number / negative) never throws and
        -- restarts from a sane value.
        local ok = pcall(function()
            sb.Mods._relay._update = "bogus"
            sb.Mods._relay._update_bump()
            runner.assert_eq(1, sb.Mods._relay._update,
                "a non-number counter resets to 0 then increments")
            sb.Mods._relay._update = -5
            sb.Mods._relay._update_bump()
            runner.assert_eq(1, sb.Mods._relay._update,
                "a negative counter clamps to 0 then increments")
        end)
        runner.assert_eq(true, ok, "the bump must never throw")
        -- frame_stamp renders a corrupted counter as update=0, never throws.
        sb.Mods._relay._update = {}
        local ok2, stamp = pcall(sb.Mods._relay.frame_stamp)
        runner.assert_eq(true, ok2)
        runner.assert_eq(" update=0 frame=?", stamp)
    end)

    runner.register("entry: a malformed (non-string) baked global degrades to trace off (never a failure path)", function()
        local sb, logged = run_init_trace({ bogus = true })  -- non-string baked value
        runner.assert_eq(true, sb.Mods._loaded,
            "the entry still succeeds with a malformed baked value")
        runner.assert_eq(false, sb.Mods._relay._trace_enabled,
            "a non-string baked value degrades to trace off")
        runner.assert_nil(sb.RELAY_LOG_LEVEL,
            "even a malformed trampoline global is retired")
        sb.Mods._relay.log_trace("anything")
        runner.assert_eq(0, #logged, "the gated helper stays silent")
    end)
end
