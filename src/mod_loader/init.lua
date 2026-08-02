-- init.lua — the mod loader entry.
--
-- Runs at pcall#1 in engine-context (BEFORE main.lua) to capture the engine's
-- Lua facilities before they're stripped (~pcall#6), wrap global require,
-- install the optional lua-print tee, and expose the bootstrap coordinator.
-- Class registry install, boot wrapping, and mod loading fire LATER, deferred
-- via the require bridge as main.lua runs.
--
-- Full contract (pcall#1 capture, the deferred bootstrap, the captured
-- surface, the trampoline-baked globals, the print tee):
-- docs/architecture/MOD_LOADER-DMF.md.

-- 0. Retire the optional lua-log sink temp global (one-shot C handoff). MUST
--    run before the _loaded idempotency guard below so a repeated/partial entry
--    still retires a newly-presented global. Only a function value is a valid
--    sink; anything else is retired and treated as no sink. The snapshot stays
--    private — never published under Mods/_G; only the wrapper closures below
--    retain it.
local _lua_log_sink
if type(__mod_relay_lua_log_sink) == "function" then
    _lua_log_sink = __mod_relay_lua_log_sink
end
__mod_relay_lua_log_sink = nil

-- 1. Idempotency guard. If this entry re-ran after require is wrapped,
-- recapturing `Mods.original_require = require` would grab the WRAPPED function
-- and clobber the saved original, recursing on the next require.
if Mods and Mods._loaded then
    return true
end

-- 2. Capture the engine's real facilities (present at pcall#1, before the
-- engine strips stdlib ~pcall#6).
Mods = Mods or {}
-- Relay-private bootstrap snapshot. The manager validates version content
-- before using it; malformed metadata must not abort this entry.
Mods._relay = Mods._relay or {}
Mods._relay.version = MOD_RELAY_VERSION
MOD_RELAY_VERSION = nil
-- Snapshot the optional StateSplash skip (trampoline-set global). Nil-safe.
-- lifecycle.lua reads this once at module-eval time. Internal/private.
Mods._relay.skip_splash = (RELAY_SKIP_SPLASH == "1")
RELAY_SKIP_SPLASH = nil
do
    local ok, traceback_fn = pcall(function()
        if type(debug) == "table" and type(debug.traceback) == "function" then
            return debug.traceback
        end
        return nil
    end)
    Mods._relay.traceback = ok and traceback_fn or nil
end
Mods.original_require = require
Mods.require_store = {}
Mods.lua = Mods.lua or {}
Mods.lua.loadstring = loadstring
Mods.lua.io = io
-- Captured before the os/ffi block so the FFI diagnostic below uses the same
-- print surface as the rest of the loader.
__print = __print or print

-- Install the optional lua-print tee (process-lifetime, non-stacking). Wraps
-- global print and __print so every SUCCESSFUL print also reaches the Relay
-- shell log: the original is called FIRST with exact args and its error
-- propagates; only then does a protected capture render args and hand one
-- string to the private sink. Sink/render failures are swallowed — they never
-- change a successful call's results. With no sink, print is untouched.
-- Mods._relay._print_tee_installed makes the wrap idempotent: hot reload never
-- re-runs this entry, and a mod that later replaces print wins (no fight).
if _lua_log_sink and not Mods._relay._print_tee_installed then
    local _sink = _lua_log_sink

    -- Capture the stdlib functions ONCE at install. The wrappers are process-
    -- lifetime and close over these locals so they keep working even if later
    -- engine stripping or community mutation replaces/removes the globals.
    local _pcall = pcall
    local _select = select
    local _unpack = unpack
    local _type = type
    local _tostring = tostring
    local _concat = table.concat

    -- Render one print argument list into a single tab-delimited string.
    -- Strings/numbers/booleans/nil use textual forms; tables/functions/etc use
    -- stable type placeholders so a user __tostring metamethod (already invoked
    -- once by the original print) is never re-invoked. Multiline content passes
    -- through intact — the native sink owns CR/LF splitting, control-byte
    -- sanitization, and chunking. No Lua 5.2+ APIs.
    local function _render_args(args, n_args)
        if n_args == 0 then return "" end
        local parts = {}
        for i = 1, n_args do
            local v = args[i]
            local tp = _type(v)
            if tp == "string" then
                parts[i] = v
            elseif tp == "number" then
                parts[i] = _tostring(v)
            elseif tp == "boolean" then
                parts[i] = v and "true" or "false"
            elseif tp == "nil" then
                parts[i] = "nil"
            elseif tp == "table" then
                parts[i] = "<table>"
            elseif tp == "function" then
                parts[i] = "<function>"
            elseif tp == "thread" then
                parts[i] = "<thread>"
            elseif tp == "cdata" then
                -- LuaJIT 2.1: type(ffi.new(...)) == "cdata", distinct from userdata.
                parts[i] = "<cdata>"
            else
                parts[i] = "<userdata>"
            end
        end
        return _concat(parts, "\t")
    end

    -- Run render + sink under one pcall so a failure in either is swallowed.
    local function _capture(args, n_args)
        _sink(_render_args(args, n_args))
    end

    -- 5.1-compatible varargs pack: records the count so unpack preserves
    -- interior/trailing nils.
    local function _pack_n(...)
        return { n = _select("#", ...), ... }
    end

    -- Wrap one original print surface. The original is called DIRECTLY, not under
    -- pcall: if it throws, the error escapes naturally with its frame + traceback
    -- intact (a pcall+rethrow would unwind the frame first). On success the
    -- results are packed with their count, protected capture runs, and results
    -- are forwarded via unpack(t,1,n) so nil cardinality is preserved.
    local function _make_wrapper(original)
        return function(...)
            local n_args = _select("#", ...)
            local args = {...}
            local results = _pack_n(original(...))
            _pcall(_capture, args, n_args)
            return _unpack(results, 1, results.n)
        end
    end

    local _orig_print = print
    local _orig_dunder = __print
    local _print_is_fn = _type(_orig_print) == "function"
    local _dunder_is_fn = _type(_orig_dunder) == "function"

    -- Set the marker FIRST so a mid-wrap fault can never stack a second wrapper.
    Mods._relay._print_tee_installed = true

    if _print_is_fn and _dunder_is_fn and _orig_print == _orig_dunder then
        -- Same surface: one shared wrapper on both globals (no double capture).
        local _w = _make_wrapper(_orig_print)
        print = _w
        __print = _w
    else
        -- Distinct/singly-present surfaces: wrap each around its own original; never
        -- touch a non-function global (no "repairing" of malformed engine state).
        if _print_is_fn then
            print = _make_wrapper(_orig_print)
        end
        if _dunder_is_fn then
            __print = _make_wrapper(_orig_dunder)
        end
    end
end

-- os may be absent in a stripped build; `or` preserves a prior capture on re-run.
Mods.lua.os = Mods.lua.os or os

-- Shared loader diagnostic logger, published on Mods._relay BEFORE the module
-- bootstrap loop so every loader module reads the same helper. The print runs
-- under pcall and the message through safe_text so a bad argument or print
-- failure can NEVER become a second failure path that breaks loading. Mechanism
-- only — no level threshold: prints go to the console log unfiltered, and level
-- filtering is the shell/tee's job. _print is post-tee __print so diagnostics
-- are tee'd when --log-lua is on.
do
    local _pcall = pcall
    local _tostring = tostring
    local _type = type
    local _print = __print
    local function safe_text(value)
        local ok, text = _pcall(_tostring, value)
        if ok and _type(text) == "string" then
            return text
        end
        return "<unprintable error>"
    end
    local function make_logger(level)
        return function(message)
            _pcall(_print, level .. " [mod_loader] " .. safe_text(message))
        end
    end
    Mods._relay.log_info  = make_logger("INFO")
    Mods._relay.log_debug = make_logger("DEBUG")
    Mods._relay.log_warn  = make_logger("WARN")
    Mods._relay.log_error = make_logger("ERROR")
end

-- Publish the engine LuaJIT FFI module at the community contract surface.
-- require("ffi") creates no global in LuaJIT 2.1, so it is obtained from the
-- PRE-WRAP original require (the wrapped global would record into
-- require_store and advance the bootstrap coordinator). Degrades to nil with
-- one diagnostic on failure; never aborts the loader.
if Mods.lua.ffi == nil and type(Mods.original_require) == "function" then
    local ok, result = pcall(Mods.original_require, "ffi")
    if ok and type(result) == "table" then
        Mods.lua.ffi = result
    else
        Mods._relay.log_warn("ffi module unavailable; Mods.lua.ffi remains nil")
    end
end
-- The mod path (RELAY_MOD_PATH). _mod_path is the dir containing a
-- `mods/` subdir; _mod_root is derived as _mod_path .. "/mods" (what Mods.file.*
-- roots at, and what the Mods.lua.io.open/io.lines wrapper roots relative paths
-- at — absolute paths pass through verbatim). Strip only the
-- trailing separator here — do NOT convert backslashes to forward, which would
-- mangle a UNC path (\\server\share -> //server/share) that normpath does NOT
-- recover as UNC on Windows; normpath normalizes downstream. Empty/missing
-- _mod_path => empty _mod_root (mods won't load).
Mods._mod_path = RELAY_MOD_PATH or ""
local _mp = Mods._mod_path
if _mp ~= "" then
    _mp = _mp:gsub("[/\\]+$", "")
    Mods._mod_path = _mp
    Mods._mod_root = _mp .. "/mods"
else
    Mods._mod_root = ""
end

local _io = Mods.lua.io
-- Capture the raw io.open for _load_module. file.lua's wrapper replaces
-- Mods.lua.io.open; since _io is a table reference, _io.open would become the
-- wrapper too. Capturing the function directly keeps loader-module reads raw
-- (the wrapper would double-prefix loader-root paths and break bootstrap).
local _io_open = _io.open
local _loadstring = Mods.lua.loadstring
local _pcall = pcall
local _setfenv = setfenv
local _getfenv = getfenv

-- Shared dofile-style loader for Relay modules, rooted at MOD_LOADER_DIR.
-- Runs the chunk in the entry's env (setfenv so modules share _G) and returns
-- (ok, result); logs an ERROR on open/parse/run failure.
local function _load_module(name)
    local base = MOD_LOADER_DIR or ""
    local path = base .. "/" .. name .. ".lua"

    local f, err = _io_open(path, "r")
    if not f then
        Mods._relay.log_error("cannot open " .. path .. ": " .. tostring(err))
        return false, nil
    end
    local data = f:read("*all")
    f:close()

    local fn, lerr = _loadstring(data, path)
    if not fn then
        Mods._relay.log_error("cannot parse " .. path .. ": " .. tostring(lerr))
        return false, nil
    end
    _setfenv(fn, _getfenv(1))

    local ok, rerr = _pcall(fn)
    if not ok then
        Mods._relay.log_error("error running " .. path .. ": " .. tostring(rerr))
        return false, nil
    end
    return true, rerr
end

-- Install-only contract for the entry's bootstrap loop.
local function bootstrap_load(name)
    local ok = _load_module(name)
    return ok
end

-- Dofile-style loader for the lifecycle bootstrap to load mod_manager from the
-- loader root AFTER class() exists (mod_manager calls class("ModManager")).
Mods.load_module = function(name)
    local ok, result = _load_module(name)
    if ok then
        return result
    end
    return nil
end

-- 3. Bootstrap-load the helper modules from the loader root, in dependency
-- order. A module failure aborts entry safely (logs + returns false).
local modules = { "file", "class_registry", "lifecycle", "require_bridge" }
for _, mod in ipairs(modules) do
    if not bootstrap_load(mod) then
        Mods._relay.log_error("bootstrap aborted at module '" .. mod .. "'")
        return false
    end
end

-- 4. Wrap global require (records table results into Mods.require_store and
-- drives the bootstrap coordinator after each successful require).
Mods.install_require_bridge()

Mods._relay.log_info("loaded at pcall#1")
Mods._loaded = true
return true
