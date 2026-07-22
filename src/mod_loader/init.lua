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

-- 0. Idempotency guard. The C trampoline is one-shot, but if this entry ever
-- re-ran after global require is wrapped, recapturing `Mods.original_require
-- = require` would grab the WRAPPED function and clobber the saved original,
-- recursing on the next require. Bail if we've already loaded.
if Mods and Mods._loaded then
    return true
end

-- 1. Capture the engine's real facilities (present at pcall#1, before the
-- engine strips stdlib ~pcall#6). These are the surfaces DMF consumes:
--   - Mods.original_require  (DMF core/require.lua uses it as the unhooked req)
--   - Mods.require_store     (DMF hook_require iterates per-path instances)
--   - Mods.lua.{io,loadstring,os,ffi}  (DMF deep-copies io/loadstring; its
--       debug modules read os/ffi)
--   - __print                (DMF aliases the engine print via __print)
Mods = Mods or {}
Mods.original_require = require
Mods.require_store = {}
Mods.lua = Mods.lua or {}
Mods.lua.loadstring = loadstring
Mods.lua.io = io
-- __print is captured here (ahead of the os/ffi block) so the FFI diagnostic
-- below uses the same print surface as the rest of the loader.
__print = __print or print
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

-- 2. Bootstrap-load the helper modules from the loader root, in dependency
-- order. A module failure aborts entry safely (logs + returns false).
local modules = { "file", "class_registry", "lifecycle", "require_bridge" }
for _, mod in ipairs(modules) do
    if not bootstrap_load(mod) then
        _print("[mod_loader] bootstrap aborted at module '" .. mod .. "'")
        return false
    end
end

-- 3. Wrap global require. The wrapped require records table results into
-- Mods.require_store (identity-deduped) and calls the lifecycle bootstrap
-- coordinator after every successful require.
Mods.install_require_bridge()

_print("[mod_loader] loaded at pcall#1")
Mods._loaded = true
return true
