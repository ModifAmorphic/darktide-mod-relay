-- mock.lua — mocked engine environment for the offline LuaJIT harness.
--
-- Provides per-test isolation via sandboxing (setfenv): each module under test
-- runs in a fresh sandbox that has the real stdlib, a sandbox-aware loadstring
-- (so any module code that resolves globals at chunk-load time sees the
-- sandbox, not the real _G), and whatever mocks the test injects (Mods, io,
-- require, class).
--
-- Module sources are read from the real filesystem (../<name>.lua relative to
-- this tests/ dir) and loaded into a sandbox with mock.load_module.
--
-- TWO-ROOT MODEL (mirrors the production split the C trampoline sets up):
--   - Loader root  (MOD_LOADER_DIR) — runtime-controlled, INTERNAL (trampoline-
--     set); holds init.lua + its active modules. bootstrap_load roots here.
--     The mock default is mock.MOD_LOADER_ROOT ("/mod_loader");
--     mock.stage_mod_loader() builds the files map a test io mock serves for it.
--   - Mod root     (RELAY_MOD_PATH) — user/mod-manager-controlled; holds
--     mods.lst + dmf/ + user mods. Mods.file.* roots here. The mock
--     default is mock.MOD_ROOT ("/mods"); each test stages its own mods/DMF.

local _G = _G
local assert = assert
local error = error
local getinfo = debug.getinfo
local ipairs = ipairs
local io = io
local loadstring = loadstring
local setfenv = setfenv
local tostring = tostring

local M = {}

-- The two mock roots (production split). Tests set these onto the sandbox as
-- MOD_LOADER_DIR / RELAY_MOD_PATH; the entry's bootstrap_load roots at the
-- loader root, Mods.file.* at the mod root.
M.MOD_LOADER_ROOT = "/mod_loader"
M.MOD_ROOT = "/mods"

-- The conventional staged alternate mod manager path (RELAY_MOD_MANAGER /
-- --mod-manager). Tests set this onto the sandbox as the trampoline-baked
-- RELAY_MOD_MANAGER global and stage their replacement-manager chunk at the
-- same key in the io files map. Production bakes the user-configured path
-- VERBATIM — tests asserting verbatim pass-through stage their own exact
-- strings (the io mock normalizes only its own lookup keys, never the arg).
M.MOD_MANAGER_PATH = "/alt/mod_manager.lua"

-- The loader's active modules (the entry bootstraps them in this order).
-- Excludes tests/ (harness) — not runtime.
M.MOD_LOADER_MODULES = { "file", "class_registry", "lifecycle", "require_bridge" }

-- stdlib globals every sandbox starts with (so the modules' locals like
-- `local pairs = pairs` resolve). `package` is included so path.lua's
-- platform detection (`package.config:sub(1,1)`) works under the harness.
local STDLIB = {
    "print", "pairs", "ipairs", "tostring", "tonumber", "type",
    "assert", "error", "pcall", "xpcall", "select",
    "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "rawlen",
    "unpack", "setfenv", "getfenv", "loadstring", "load", "loadfile", "dofile",
    "next", "string", "table", "math", "os", "coroutine", "debug",
    "package", "_VERSION",
}

-- Build a fresh sandbox: real stdlib + sandbox-aware loadstring + _G = sandbox.
-- The sandbox-aware loadstring compiles chunks so they resolve globals against
-- the sandbox instead of the real _G (modules under test share the sandbox).
function M.new_sandbox()
    local sb = {}
    for _, k in ipairs(STDLIB) do
        sb[k] = _G[k]
    end
    local real_loadstring = _G.loadstring
    sb.loadstring = function(src, name)
        local fn, err = real_loadstring(src, name)
        if fn then
            setfenv(fn, sb)
        end
        return fn, err
    end
    sb._G = sb
    return sb
end

-- In-memory io mock. `files` is a map of absolute path -> content string.
-- Returned table has .open(path, mode) -> file object with :read/:lines/:close,
-- plus .close(f) for parity with the real io API.
--
-- Path lookup is separator-agnostic: lookup keys have backslashes normalized to
-- forward slashes before hitting the files map. This mirrors Windows filesystem
-- behavior (where / and \ are interchangeable) and lets tests stage files with
-- forward slashes (the existing convention) while the Mods.lua.io wrapper
-- resolves to platform-native paths (backslashes on Windows). Existing callers
-- that already use forward slashes are unaffected (the normalization is a
-- no-op on forward-slash paths).
function M.make_io(files)
    local iot = {}

    local function normkey(p)
        return (p:gsub("\\", "/"))
    end

    local function make_file(content)
        local f = {}
        local pos = 1
        function f:read(opt)
            if opt == nil or opt == "*all" or opt == "a" then
                local r = content:sub(pos)
                pos = #content + 1
                return r
            elseif opt == "*l" or opt == "l" then
                local nl = content:find("\n", pos, true)
                local line
                if nl then
                    line = content:sub(pos, nl - 1)
                    pos = nl + 1
                else
                    line = content:sub(pos)
                    pos = #content + 1
                end
                return line
            elseif opt == "L" then
                local nl = content:find("\n", pos, true)
                local line
                if nl then
                    line = content:sub(pos, nl)
                    pos = nl + 1
                else
                    line = content:sub(pos)
                    pos = #content + 1
                end
                return line
            elseif opt == "*n" or opt == "n" then
                local s, e, num = content:find("^%s*([-%d.]+)", pos)
                if num then
                    pos = e + 1
                    return tonumber(num)
                end
                return nil
            end
            error("mock io: unsupported read opt " .. tostring(opt))
        end
        function f:lines(...)
            return function()
                if pos > #content then return nil end
                local nl = content:find("\n", pos, true)
                local line
                if nl then
                    line = content:sub(pos, nl - 1)
                    pos = nl + 1
                else
                    line = content:sub(pos)
                    pos = #content + 1
                end
                return line
            end
        end
        function f:close() end
        return f
    end

    function iot.open(path, mode)
        local content = files[normkey(path)]
        if content == nil then
            return nil, path .. ": mock not found"
        end
        return make_file(content)
    end
    function iot.close(f)
        if f and f.close then f:close() end
    end
    function iot.lines(path)
        local content = files[normkey(path)]
        if content == nil then error("mock io: not found " .. path) end
        local f = make_file(content)
        return f:lines()
    end
    return iot
end

-- Resolve the directory of this file so test files can find sibling modules.
local this_dir = getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
M.module_dir = this_dir .. "../"

-- Read a real file from disk (for loading module sources under test).
function M.read_file(path)
    local f = assert(io.open(path, "r"))
    local data = f:read("*all")
    f:close()
    return data
end

-- Read a module source from src/mod_loader/<name>.lua.
function M.read_module(name)
    return M.read_file(M.module_dir .. name .. ".lua")
end

-- Build the loader-root files map (the runtime-controlled root): init.lua +
-- every active module, keyed at <MOD_LOADER_ROOT>/<name>.lua. Mirrors the
-- deployment contract (bin/mod_loader/) and what bootstrap_load expects to
-- open. A test merges this into its io-mock files map (and adds its own
-- mod-root files under MOD_ROOT for DMF/mods/mods.lst).
function M.stage_mod_loader()
    local files = {}
    for _, name in ipairs(M.MOD_LOADER_MODULES) do
        files[M.MOD_LOADER_ROOT .. "/" .. name .. ".lua"] = M.read_module(name)
    end
    files[M.MOD_LOADER_ROOT .. "/init.lua"] = M.read_module("init")
    -- path.lua is loaded on-demand by file.lua (not in the bootstrap list),
    -- but must be staged at the loader root so Mods.load_module("path") finds it.
    files[M.MOD_LOADER_ROOT .. "/path.lua"] = M.read_module("path")
    -- dmf_adapter.lua is loaded on-demand by lifecycle.lua at module scope
    -- (published on Mods._relay.dmf_adapter; mod_manager reads it from there),
    -- so it must likewise be staged at the loader root.
    files[M.MOD_LOADER_ROOT .. "/dmf_adapter.lua"] = M.read_module("dmf_adapter")
    return files
end

-- Compile + load a module source into a sandbox. Returns the chunk (caller runs
-- it). Equivalent to the entry's bootstrap_load minus the io step.
function M.load_module(name, sb)
    local src = M.read_module(name)
    local fn = assert(loadstring(src, name .. ".lua"))
    setfenv(fn, sb)
    return fn
end

-- Convenience: load + run a module into a sandbox.
function M.run_module(name, sb)
    return M.load_module(name, sb)()
end

-- Publish the loader's diagnostic logger onto sb.Mods._relay (the test fake of
-- the helper init.lua publishes in production onto the same surface). Every
-- loader module reads its leveled prints from Mods._relay.log_<level>; a test
-- that loads a logging module (file/lifecycle/mod_manager) WITHOUT running
-- init.lua must call this so those modules resolve real functions instead of
-- nil. Routes to sb.__print dynamically so a per-test print spy captures the
-- formatted "{LEVEL} [mod_loader] {message}" line. Preserves any fields already
-- on Mods / Mods._relay (version, skip_splash, traceback, ...). Idempotent: a
-- second call keeps the already-attached (or init-published) loggers. Call AFTER
-- sb.Mods and sb.__print exist and BEFORE mock.run_module loads a logging module.
function M.attach_logger(sb)
    local mods = sb.Mods
    if type(mods) ~= "table" then
        mods = {}
        sb.Mods = mods
    end
    local relay = mods._relay
    if type(relay) ~= "table" then
        relay = {}
        mods._relay = relay
    end
    local function make(level)
        return function(message)
            sb.__print(level .. " [mod_loader] " .. tostring(message))
        end
    end
    relay.log_info  = relay.log_info  or make("INFO")
    relay.log_debug = relay.log_debug or make("DEBUG")
    relay.log_warn  = relay.log_warn  or make("WARN")
    relay.log_error = relay.log_error or make("ERROR")
    -- The loader-relative tick counter (init.lua publishes the real one on
    -- Mods._relay; seeded here so isolated module tests can read — and inject,
    -- by assignment — a tick source).
    if relay._tick == nil then
        relay._tick = 0
    end
    -- frame_stamp mirrors init.lua's helper: " tick=N frame=M" from the
    -- injectable relay._tick + the sandbox's FRAME_INDEX (sb._G == sb, so
    -- this is the module-side rawget(_G, ...)); " frame=?" when absent or
    -- non-number; a corrupted _tick renders as 0.
    if relay.frame_stamp == nil then
        relay.frame_stamp = function()
            local t = relay._tick
            if type(t) ~= "number" or t < 0 then t = 0 end
            local n = rawget(sb, "FRAME_INDEX")
            local f = type(n) == "number" and tostring(n) or "?"
            return " tick=" .. tostring(t) .. " frame=" .. f
        end
    end
    -- _tick_bump mirrors init.lua's helper (defensive reset + increment).
    if relay._tick_bump == nil then
        relay._tick_bump = function()
            local t = relay._tick
            if type(t) ~= "number" or t < 0 then t = 0 end
            relay._tick = t + 1
        end
    end
    -- display_text mirrors init.lua's shared scrubber (real semantics —
    -- tests assert scrubbed/capped output through it): pcall'd tostring,
    -- control bytes -> '?', 80-byte display cap (77 + "...").
    if relay.display_text == nil then
        relay.display_text = function(value)
            local ok, text = pcall(tostring, value)
            if not ok or type(text) ~= "string" then
                return "<unprintable error>"
            end
            local rendered = text:gsub("%c", "?")
            if #rendered > 80 then
                rendered = rendered:sub(1, 77) .. "..."
            end
            return rendered
        end
    end
    -- log_trace mirrors init.lua's gated helper, but reads the injectable
    -- relay._trace_enabled flag at CALL time so isolated module tests can
    -- exercise both states without re-running the entry (init bakes its gate
    -- once, at entry time).
    if relay.log_trace == nil then
        relay.log_trace = function(message)
            if relay._trace_enabled ~= true then return end
            sb.__print("TRACE [mod_loader] " .. tostring(message) .. relay.frame_stamp())
        end
    end
end

return M
