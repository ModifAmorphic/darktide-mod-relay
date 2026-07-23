-- init.lua — the mod loader entry.
--
-- Runs at pcall#1 in engine-context (delivered by the runtime trampoline),
-- BEFORE main.lua executes. Captures the engine's Lua facilities before the
-- engine strips them from globals (~pcall#6), bootstrap-loads the Relay
-- modules from the loader root, wraps global require, and exposes the
-- bootstrap coordinator. The class registry install, boot wrapping, and mod
-- loading fire LATER, deferred via the require bridge as main.lua runs.
--
-- Two roots (globals set by the C trampoline before opening this entry):
--   - MOD_LOADER_DIR       — runtime-controlled, INTERNAL (trampoline-set, not
--                            a user env var/flag). This file + its modules
--                            (file/class_registry/lifecycle/require_bridge +
--                            mod_manager + dmf_adapter + path) live here.
--   - RELAY_MOD_PATH   — user/mod-manager-controlled. The mod-path
--                            BOUNDARY: a directory that contains a `mods/`
--                            subdirectory. DMF + user mods + mods.lst live at
--                            <mod_path>/mods/. Mods.file.* roots at
--                            Mods._mod_root (= _mod_path .. "/mods"); the
--                            Mods.lua.io wrapper contains reads at _mod_path.
--   - MOD_RELAY_VERSION — runtime-controlled, INTERNAL one-shot handoff of the
--                         manifest-derived product version. Snapshotted below
--                         and immediately retired; it is not a community API.
--
-- The mod-path boundary contract:
--   - Mods._mod_path  = RELAY_MOD_PATH (the boundary; parent of `mods/`).
--   - Mods._mod_root  = _mod_path .. "/mods" (the mods dir; what Mods.file.*
--                       roots at — unchanged semantics for the internal ops).
-- Splitting the two lets the Mods.lua.io wrapper contain raw io.open/io.lines
-- reads at _mod_path (so DMF's "./../mods/<mod>/<rest>" convention resolves
-- correctly) while Mods.file.* continues to root at _mod_root as before.
--
-- Module bootstrap order: file -> class_registry -> lifecycle -> require_bridge.
-- Each module assumes its dependencies are already on Mods/_G. mod_manager is
-- loaded LATER by the lifecycle bootstrap (it calls class(), which only exists
-- once the class registry installs during main.lua's requires); mod_manager
-- in turn loads dmf_adapter (the stock-DMF compatibility boundary) at its
-- module top before class("ModManager").

-- 0. Retire the optional lua-log sink temp global (one-shot C handoff). The C
--    trampoline publishes __mod_relay_lua_log_sink — when the user opts in via
--    RELAY_LUA_LOGS=1 — immediately before running this chunk, and expects the
--    loader to consume it here and clear it. This MUST run before the _loaded
--    idempotency guard below so a repeated/partial entry retires a newly-
--    presented global even when the guard bails early (the trampoline is
--    one-shot, but the retirement is defensive). Only a function value is a
--    valid sink; any other value (absent/nil, or a stray non-function) is
--    retired and treated as no sink. The snapshot stays local + private — it is
--    never published under Mods, _G, or any community surface; only the wrapper
--    closures below retain it.
local _lua_log_sink
if type(__mod_relay_lua_log_sink) == "function" then
    _lua_log_sink = __mod_relay_lua_log_sink
end
__mod_relay_lua_log_sink = nil

-- 1. Idempotency guard. The C trampoline is one-shot, but if this entry ever
-- re-ran after global require is wrapped, recapturing `Mods.original_require
-- = require` would grab the WRAPPED function and clobber the saved original,
-- recursing on the next require. Bail if we've already loaded.
if Mods and Mods._loaded then
    return true
end

-- 2. Capture the engine's real facilities (present at pcall#1, before the
-- engine strips stdlib ~pcall#6). These are the surfaces DMF consumes:
--   - Mods.original_require  (DMF core/require.lua uses it as the unhooked req)
--   - Mods.require_store     (DMF hook_require iterates per-path instances)
--   - Mods.lua.{io,loadstring,os,ffi}  (DMF deep-copies io/loadstring; its
--       debug modules read os/ffi)
--   - __print                (DMF aliases the engine print via __print)
Mods = Mods or {}
-- Relay-private bootstrap snapshot. Keep the narrow capabilities needed by
-- later loader modules without publishing the debug library or retaining the
-- temporary C-trampoline global. The manager validates version content before
-- using it; malformed metadata must not abort this entry.
Mods._relay = Mods._relay or {}
Mods._relay.version = MOD_RELAY_VERSION
MOD_RELAY_VERSION = nil
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
-- __print is captured here (ahead of the os/ffi block) so the FFI diagnostic
-- below uses the same print surface as the rest of the loader.
__print = __print or print

-- Install the optional lua-log tee (process-lifetime, non-stacking). With a
-- valid sink (snapshotted + retired above), wrap the engine's global print and
-- __print so every SUCCESSFUL print also reaches the Relay shell log, best
-- effort. The originals stay authoritative: each wrapper calls its own original
-- FIRST with the exact args, propagates any error (capture skipped), and only
-- then — under protected capture — renders the args and hands one string to the
-- private sink. Renderer/sink failures are swallowed; they never change a
-- successful call's results. With no sink, today's behavior is exactly
-- preserved (print untouched; __print = __print or print already resolved).
--
-- A Relay-private marker under Mods._relay makes the wrap idempotent: a
-- partial/repeated entry cannot stack wrappers, and hot reload (which reuses
-- this same Lua state but never re-runs this one-shot entry) neither removes
-- nor reinstalls them. A mod that later replaces global print wins — the
-- wrapper does not fight it. Installed here, ahead of the os/ffi block, so the
-- FFI diagnostic and every later loader module / DMF / user-mod print is tee'd.
if _lua_log_sink and not Mods._relay._print_tee_installed then
    local _sink = _lua_log_sink

    -- Capture the exact stdlib functions the wrappers need, ONCE, at install.
    -- The wrappers are process-lifetime and must keep working even if later
    -- engine stripping (~pcall#6) or community mutation replaces or removes the
    -- globals. Each wrapper closes over these locals, so it never does a dynamic
    -- global lookup for pcall/select/unpack/type/tostring/table.concat — the
    -- original is the only other private upvalue.
    local _pcall = pcall
    local _select = select
    local _unpack = unpack
    local _type = type
    local _tostring = tostring
    local _concat = table.concat

    -- Render one print argument list (n_args values in args[1..n_args]) into a
    -- single tab-delimited string for the sink. Strings pass through byte-for-
    -- byte; numbers/booleans/nil use ordinary textual forms; tables/functions/
    -- threads/cdata/userdata use stable type placeholders, so a user __tostring
    -- metamethod (which the original print already invoked once) is never
    -- invoked a second time. An empty arg list renders as "". Multiline content
    -- is handed through intact — the native sink owns CR/LF splitting,
    -- control-byte sanitization, and chunking/truncation. No Lua 5.2+ APIs.
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
                -- LuaJIT 2.1: type(ffi.new(...)) == "cdata". Distinct from
                -- userdata (a different type() return); gets its own placeholder
                -- so the value is never re-converted and no metamethod runs.
                parts[i] = "<cdata>"
            else
                parts[i] = "<userdata>"
            end
        end
        return _concat(parts, "\t")
    end

    -- Run render + sink under one pcall so a failure in EITHER is swallowed
    -- (never changes a successful print). Takes the materialized args table +
    -- count so it needs no access to the wrapper's varargs.
    local function _capture(args, n_args)
        _sink(_render_args(args, n_args))
    end

    -- Lua-5.1-compatible varargs pack: records the EXACT count alongside the
    -- values so a later _unpack(t, 1, t.n) preserves interior/trailing nils
    -- (table construction drops nil slots, but unpack with an explicit stop
    -- index pushes nil for absent integer keys, so cardinality is recovered).
    local function _pack_n(...)
        return { n = _select("#", ...), ... }
    end

    -- Build a wrapper around one original print surface. The original is called
    -- DIRECTLY (NOT under pcall): if it throws, evaluation aborts before capture
    -- is attempted and the error escapes naturally — its value, stack frames,
    -- and traceback provenance are preserved for any outer pcall/xpcall/debug
    -- handler (a pcall+rethrow would unwind the original's frame first). On
    -- success the results are packed with their exact count, protected capture
    -- runs, and the results are forwarded via _unpack(t, 1, n) so zero,
    -- interior-nil, and trailing-nil cardinality are all preserved.
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

    -- Set the marker FIRST so even a mid-wrap fault can never stack a second
    -- wrapper on re-entry (Lua is single-threaded; the wrap is synchronous, but
    -- the guard is defensive against a partial entry that errored later).
    Mods._relay._print_tee_installed = true

    if _print_is_fn and _dunder_is_fn and _orig_print == _orig_dunder then
        -- Same surface (e.g. __print was nil and resolved to print above): one
        -- shared wrapper on both globals — no nested/double capture.
        local _w = _make_wrapper(_orig_print)
        print = _w
        __print = _w
    else
        -- Distinct or singly-present function surfaces: wrap each function
        -- around its own original; do not collapse them, and do not touch a
        -- non-function global (no "repairing" of malformed engine state).
        if _print_is_fn then
            print = _make_wrapper(_orig_print)
        end
        if _dunder_is_fn then
            __print = _make_wrapper(_orig_dunder)
        end
    end
end

-- os is captured nil-safe (it may be absent in a stripped engine build). `or`
-- preserves a prior capture if init re-ran.
Mods.lua.os = Mods.lua.os or os
-- Publish the engine LuaJIT FFI module at the community contract surface.
-- require("ffi") creates no global in LuaJIT 2.1, so a global grab yields nil;
-- the module is obtained from the pre-wrap original require (NOT the wrapped
-- global, which would record into Mods.require_store and advance the bootstrap
-- coordinator). Guarded + exactly-once (the _loaded guard already prevents
-- re-entry); a failure / nil / non-table degrades to nil with one diagnostic,
-- never aborting the loader.
if Mods.lua.ffi == nil and type(Mods.original_require) == "function" then
    local ok, result = pcall(Mods.original_require, "ffi")
    if ok and type(result) == "table" then
        Mods.lua.ffi = result
    else
        __print("[mod_loader] ffi module unavailable; Mods.lua.ffi remains nil")
    end
end
-- The mod-path boundary (RELAY_MOD_PATH). _mod_path is the boundary — the
-- directory that CONTAINS a `mods/` subdir. _mod_root is derived as
-- _mod_path .. "/mods" (the mods dir, what Mods.file.* roots at — unchanged
-- semantics for the existing internal operations). Strip only the trailing
-- separator from _mod_path — do NOT convert backslashes to forward here (that
-- would mangle a UNC path like \\server\share into //server/share, which
-- normpath does NOT recover as UNC on Windows). normpath handles separator
-- normalization downstream (it does its own P:gsub('/', '\\') on Windows and
-- correctly preserves UNC/drive anchors). Empty/missing _mod_path => empty
-- _mod_root (mods won't load; same behavior as before).
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
-- Capture the raw io.open for _load_module. file.lua's wrapper (installed when
-- _mod_path is set) replaces Mods.lua.io.open; since _io is a table reference,
-- _io.open would become the wrapper too. Capturing the function directly keeps
-- loader-module reads on the raw surface (the wrapper would double-prefix
-- loader-root paths and break the bootstrap).
local _io_open = _io.open
local _loadstring = Mods.lua.loadstring
local _pcall = pcall
local _setfenv = setfenv
local _getfenv = getfenv
local _print = __print

-- _load_module — the shared dofile-style loader for Relay modules, rooted at
-- MOD_LOADER_DIR. Reads + compiles + runs the chunk in the entry's env
-- (setfenv(fn, getfenv(1)) so modules share _G with the entry — the engine's
-- globals in production, the test sandbox in tests). Returns (ok, result):
-- ok is true/false; result is the chunk's return value on success or nil on
-- failure. Logs a FATAL line on open/parse/run failure so a mis-staged module
-- is diagnosable in the shell log.
local function _load_module(name)
    local base = MOD_LOADER_DIR or ""
    local path = base .. "/" .. name .. ".lua"

    local f, err = _io_open(path, "r")
    if not f then
        _print("[mod_loader] FATAL: cannot open " .. path .. ": " .. tostring(err))
        return false, nil
    end
    local data = f:read("*all")
    f:close()

    local fn, lerr = _loadstring(data, path)
    if not fn then
        _print("[mod_loader] FATAL: cannot parse " .. path .. ": " .. tostring(lerr))
        return false, nil
    end
    _setfenv(fn, _getfenv(1))

    local ok, rerr = _pcall(fn)
    if not ok then
        _print("[mod_loader] FATAL: error running " .. path .. ": " .. tostring(rerr))
        return false, nil
    end
    return true, rerr
end

-- bootstrap_load — install-only contract for the entry's bootstrap loop.
local function bootstrap_load(name)
    local ok = _load_module(name)
    return ok
end

-- A dofile-style loader so the lifecycle bootstrap can load mod_manager from
-- the loader root AFTER class() exists (mod_manager calls class("ModManager"),
-- which only appears once the class registry installs during main.lua's
-- requires). Returns the chunk's result on success or nil on failure.
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
        _print("[mod_loader] bootstrap aborted at module '" .. mod .. "'")
        return false
    end
end

-- 4. Wrap global require. The wrapped require records table results into
-- Mods.require_store (identity-deduped) and calls the lifecycle bootstrap
-- coordinator after every successful require.
Mods.install_require_bridge()

_print("[mod_loader] loaded at pcall#1")
Mods._loaded = true
return true
