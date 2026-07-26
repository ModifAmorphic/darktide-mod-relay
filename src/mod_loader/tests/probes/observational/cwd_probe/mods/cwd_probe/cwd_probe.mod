-- cwd_probe.mod -- manual live diagnostic (not a harness test; not shipped).
--
-- An outer-driven observational probe that reads the live game process's
-- current working directory (CWD) three ways, plus the host executable path
-- and the mod-path context, so an operator can determine whether the CWD is
-- {GAME_DIR}\binaries before deciding whether to chdir to <mod_path>\mods.
--
-- Read-only: it installs no hooks, raises no errors, and does NOT change the
-- process working directory — it makes no Win32 directory-change call,
-- performs no chdir of any kind, and spawns no mutating shell command. It
-- only READS. (Case 3 does run `cd` via io.popen, but `cd` with no args
-- merely prints the inherited CWD — it does not mutate; the README names the
-- exact forbidden APIs and the structural test asserts their absence here.)
-- Every case is pcall-contained; a failure records a clear status=unavailable
-- marker and continues. No case can crash the game.
--
-- Install: this scenario ships a complete bundle — its directory is itself the
-- <mod_path>. Launch directly with
--   --mod-path <path-to-observational/cwd_probe>
-- (the bundle's mods/mods.lst already lists exactly `cwd_probe`). See
-- README.md in the scenario root for launch variants, expected evidence, and
-- cleanup.

-- Capture the read-only surfaces ONCE at module load. NOTE: popen is sourced
-- from Mods.lua.io, NOT the global `io`. The engine strips stdlib (io/os) from
-- globals ~pcall#6; init.lua captures io into Mods.lua.io at pcall#1 (BEFORE
-- the strip) and publishes it there for exactly this reason. .mod files load
-- much later (during main.lua's requires), so the global `io` is already gone
-- by the time this top-level runs — `io.popen` would throw "attempt to index
-- global 'io' (a nil value)" and fail the whole .mod load. Mods.lua.io.popen
-- is also the faithful surface to test: since global io is stripped, that is
-- the reference popen-using mods actually hit. Relay wraps io.open/io.lines
-- but NOT io.popen (see file.lua), so this is the raw engine popen. If it is
-- nil (engine lacks popen), the cwd_popen case degrades to status=unavailable
-- via its function-type check. FFI is acquired per-case from Mods.lua.ffi
-- (published by init.lua; may be nil if unavailable).
local _print    = print
local _tostring = tostring
local _pcall    = pcall
local _type     = type
local _popen    = Mods.lua.io.popen

local PREFIX   = "[CWD_PROBE]"
local LOG_PATH = "cwd_probe/cwd_probe.log"
local CP_UTF8  = 65001

-- Process-lifetime load index (survives hot reload via _G, same Lua state).
-- Each generation's init bumps it, so a marker's load=N aligns to one
-- generation — the basis of the no-duplicate-capture check across reloads.
local LOAD_KEY = "_RELAY_CWD_PROBE_LOAD"
if _type(_G[LOAD_KEY]) ~= "number" then _G[LOAD_KEY] = 0 end
local function load_index()
    _G[LOAD_KEY] = _G[LOAD_KEY] + 1
    return _G[LOAD_KEY]
end

-- Best-effort line emit: one line to BOTH the console (pcall'd print) AND the
-- scenario log (rooted at the mods dir via Mods.lua.io.open, append+flushed
-- per line, close ALWAYS runs so a throwing write can never leak a handle).
-- The scenario log is operator convenience (a persistent record of what the
-- probe emitted); failure on either path is swallowed. Mirrors shutdown_probe's
-- emit()/safe_append() pattern.
local function emit(line)
    _pcall(_print, line)
    _pcall(function()
        local mods = Mods
        if _type(mods) ~= "table" then return end
        local ml = mods.lua
        if _type(ml) ~= "table" then return end
        local mio = ml.io
        if _type(mio) ~= "table" then return end
        local op = mio.open
        if _type(op) ~= "function" then return end
        local f = op(LOG_PATH, "a")
        if f == nil then return end
        local wok = _pcall(function() f:write(line .. "\n") end)
        if wok and _type(f.flush) == "function" then _pcall(f.flush, f) end
        if _type(f.close) == "function" then _pcall(f.close, f) end
    end)
end

-- Run one case: `body` builds and emits its own full content line (via emit,
-- so the content reaches BOTH console and scenario log). The body runs under
-- pcall; on a contained failure, case() emits a status=unavailable marker for
-- that case instead. No case can crash the game. `tag` (load=N) is captured
-- by the body's closure.
local function case(name, tag, body)
    local ok, err = _pcall(body)
    if not ok then
        emit(PREFIX .. " case=" .. name .. " " .. tag ..
             " status=unavailable err=" .. _tostring(err))
    end
end

-- Lazily set up Win32 FFI access. Per LuaJIT FFI semantics, ffi.cdef silently
-- ignores identical re-declarations but throws "attempt to redeclare symbol"
-- on a conflicting (different-signature) one — so the cdef call is pcall'd,
-- covering both cases (the symbols are already declared from whoever ran
-- first, us or another mod/engine path; we proceed either way). Returns
-- (ffi, k32) where k32 is the kernel32 handle, or throws a contained error.
local function setup_win32()
    local ffi = Mods.lua.ffi
    if _type(ffi) ~= "table" then error("ffi unavailable", 0) end
    _pcall(ffi.cdef, [[
        uint32_t GetCurrentDirectoryW(uint32_t nBufferLength, const wchar_t* lpBuffer);
        uint32_t GetModuleFileNameW(const void* hModule, wchar_t* lpFilename, uint32_t nSize);
        int32_t  WideCharToMultiByte(uint32_t CodePage, uint32_t dwFlags,
                       const wchar_t* lpWideCharStr, int32_t cchWideChar,
                       const char* lpMultiByteStr, int32_t cbMultiByte,
                       const char* lpDefaultChar, int32_t* lpUsedDefaultChar);
    ]])
    return ffi, ffi.load("kernel32")
end

-- Convert a UTF-16 wchar_t buffer of `wlen` chars to a Lua UTF-8 string
-- (two-pass WideCharToMultiByte: size query with nil dst + cbMultiByte=0, then
-- alloc ubyte[n+1] and convert). Throws a contained error on a zero return.
local function utf16_to_utf8(ffi, k32, wbuf, wlen)
    local n = k32.WideCharToMultiByte(CP_UTF8, 0, wbuf, wlen, nil, 0, nil, nil)
    if n <= 0 then error("WideCharToMultiByte size query failed", 0) end
    local ubyte = ffi.new("char[?]", n + 1)
    local m = k32.WideCharToMultiByte(CP_UTF8, 0, wbuf, wlen, ubyte, n, nil, nil)
    if m <= 0 then error("WideCharToMultiByte convert failed", 0) end
    return ffi.string(ubyte, m)
end

return {
    run = function()
        return {
            init = function(self)
                local n = load_index()
                local tag = "load=" .. _tostring(n)
                emit(PREFIX .. " SESSION_START " .. tag)

                -- 1. cwd_ffi — primary CWD via LuaJIT FFI + Win32
                --    GetCurrentDirectoryW (UTF-16 buffer -> UTF-8).
                case("cwd_ffi", tag, function()
                    local ffi, k32 = setup_win32()
                    local wbuf = ffi.new("wchar_t[?]", 1024)
                    local wlen = k32.GetCurrentDirectoryW(1024, wbuf)
                    -- 0 = error; >= 1024 = buffer too small (need len+1 incl. NUL).
                    if wlen == 0 or wlen >= 1024 then
                        error("GetCurrentDirectoryW returned " .. _tostring(wlen), 0)
                    end
                    emit(PREFIX .. " case=cwd_ffi " .. tag ..
                         " cwd_ffi=" .. utf16_to_utf8(ffi, k32, wbuf, wlen))
                end)

                -- 2. exe_path — host executable full path via
                --    GetModuleFileNameW(NULL, …) (NULL module = current
                --    process exe; same pattern the C shell uses with
                --    GetModuleFileNameA(NULL,…), dllmain.c:315). The exe's
                --    parent directory IS {GAME_DIR}\binaries, so
                --    cwd_ffi == dir(exe_path) is the one-line answer to the
                --    research question.
                case("exe_path", tag, function()
                    local ffi, k32 = setup_win32()
                    local fbuf = ffi.new("wchar_t[?]", 1024)
                    local wlen = k32.GetModuleFileNameW(nil, fbuf, 1024)
                    if wlen == 0 or wlen >= 1024 then
                        error("GetModuleFileNameW returned " .. _tostring(wlen), 0)
                    end
                    emit(PREFIX .. " case=exe_path " .. tag ..
                         " exe_path=" .. utf16_to_utf8(ffi, k32, fbuf, wlen))
                end)

                -- 3. cwd_popen — cross-check via the engine's raw io.popen("cd").
                --    Relay wraps io.open/io.lines but NOT io.popen, so this
                --    exercises the exact raw surface popen-using mods hit,
                --    AND cross-validates the FFI answer. read is pcall'd and
                --    close ALWAYS runs after a successfully-opened popen
                --    (close itself pcall'd), so a throwing read can never
                --    leak the handle and a throwing close never escapes.
                case("cwd_popen", tag, function()
                    if _type(_popen) ~= "function" then
                        error("io.popen not a function", 0)
                    end
                    local p = _popen("cd")
                    if p == nil then error("io.popen returned nil", 0) end
                    local rok, line = _pcall(p.read, p, "*l")
                    _pcall(p.close, p)
                    if not rok then error("popen read threw", 0) end
                    if line == nil then error("popen read returned nil", 0) end
                    emit(PREFIX .. " case=cwd_popen " .. tag ..
                         " cwd_popen=" .. line)
                end)

                -- 4. context — the eventual chdir targets: the mod-path
                --    boundary (_mod_path) and the mods root (_mod_root).
                --    Guarded with type checks; <nil>/<empty> rendered clearly.
                case("context", tag, function()
                    local function render(v)
                        if _type(v) ~= "string" then return "<nil>" end
                        if v == "" then return "<empty>" end
                        return v
                    end
                    emit(PREFIX .. " case=context " .. tag ..
                         " mod_path=" .. render(Mods._mod_path) ..
                         " mod_root=" .. render(Mods._mod_root))
                end)

                emit(PREFIX .. " SESSION_DONE " .. tag)
            end,
        }
    end,
}
