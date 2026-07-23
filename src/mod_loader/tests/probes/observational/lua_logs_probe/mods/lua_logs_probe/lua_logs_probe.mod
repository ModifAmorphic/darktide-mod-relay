-- lua_logs_probe.mod -- manual live diagnostic (not a harness test; not shipped).
--
-- An outer-driven observational probe for Relay's OPTIONAL Lua print tee
-- (--lua-logs / RELAY_LUA_LOGS=1). It emits unique [LUA_LOGS_PROBE] markers
-- through the engine's global `print` and `__print` surfaces, one case per tee
-- policy: simple print, simple __print, multi-arg (primitive/nil), multiline +
-- CRLF, literal % / format-looking text, control/NUL/DEL bytes (built safely),
-- and an over-4096-byte input that triggers exactly one native truncation marker.
--
-- Read-only: it CALLS the wrapped surfaces (so console output is preserved and,
-- when the tee is on, relay.log receives the copy) and writes its own scenario
-- log. It installs no hooks, raises no errors, and never touches Relay's private
-- sink/global directly. Coverage is OBSERVED, not guaranteed: DMF may replace
-- global `print` after this mod loads; whether stock-DMF mod:info/warning/error
-- traverse the tee is a separate black-box operator check (see README.md).
--
-- Install: this scenario ships a complete bundle — its directory is itself the
-- <mod_path>. Launch directly with
--   --mod-path <path-to-observational/lua_logs_probe>
-- (the bundle's mods/mods.lst already lists exactly `lua_logs_probe`). See
-- README.md in the scenario root for launch variants, expected evidence, and
-- cleanup.

-- Capture the print surfaces ONCE at module load. At mod-load time (the LOAD
-- phase, after init.lua's one-shot wrap), global `print`/`__print` are already
-- the tee wrappers when the tee is on, or the engine originals when it is off —
-- so calling these is exactly what a mod's cached print does. `__print` may be
-- nil/absent; it is probed separately and records a clear marker if unavailable.
local _print    = print
local _dunder   = __print
local _tostring = tostring
local _pcall    = pcall
local _type     = type
local _char     = string.char
local _rep      = string.rep

local PREFIX   = "[LUA_LOGS_PROBE]"
local LOG_PATH = "lua_logs_probe/lua_logs_probe.log"

-- Process-lifetime load index (survives hot reload via _G, same Lua state). Each
-- generation's init bumps it, so a marker's load=N aligns to one generation in
-- relay.log — the basis of the no-duplicate-capture check.
local LOAD_KEY = "_RELAY_LUA_LOGS_PROBE_LOAD"
if _type(_G[LOAD_KEY]) ~= "number" then _G[LOAD_KEY] = 0 end
local function load_index()
    _G[LOAD_KEY] = _G[LOAD_KEY] + 1
    return _G[LOAD_KEY]
end

-- Best-effort scenario-log append (rooted at the mods dir via Mods.lua.io). The
-- scenario log is operator convenience (a record of what the probe emitted), not
-- evidence the probe depends on; failure is swallowed. Close ALWAYS runs so a
-- throwing write can never leak a handle. Mirrors shutdown_probe's pattern.
local function log_line(text)
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
        local wok = _pcall(function() f:write(text .. "\n") end)
        if wok and _type(f.flush) == "function" then _pcall(f.flush, f) end
        if _type(f.close) == "function" then _pcall(f.close, f) end
    end)
end

-- Run one case: `body` calls a print surface with the marker payload. Any error
-- is contained — the probe prints a clear unavailable marker and continues, so a
-- missing/odd surface never crashes the game.
local function case(name, body)
    local ok, err = _pcall(body)
    if ok then
        log_line(PREFIX .. " case=" .. name .. " status=ok")
    else
        local msg = PREFIX .. " case=" .. name .. " status=unavailable"
        _pcall(_print, msg)
        log_line(msg .. " err=" .. _tostring(err))
    end
end

return {
    run = function()
        return {
            init = function(self)
                local n = load_index()
                local tag = "load=" .. _tostring(n)
                _pcall(_print, PREFIX .. " SESSION_START " .. tag)
                log_line(PREFIX .. " SESSION_START " .. tag)

                -- 1. Simple print.
                case("simple_print", function()
                    _print(PREFIX .. " case=simple_print " .. tag .. " hello-from-print")
                end)

                -- 2. Simple __print (only when it is a function; distinct from
                --    print or aliased to it — either way this exercises the
                --    __print global the tee wraps).
                case("simple_dprint", function()
                    if _type(_dunder) ~= "function" then
                        error("__print not a function", 0)
                    end
                    _dunder(PREFIX .. " case=simple_dprint " .. tag .. " hello-from-dunder-print")
                end)

                -- 3. Multiple args incl primitive + trailing nil (select("#")
                --    preserves the count; the tee renders the nil as "nil").
                case("multi_args", function()
                    _print(PREFIX .. " case=multi_args " .. tag, 42, true, nil)
                end)

                -- 4. Multiline + CRLF: the native sink splits these into
                --    separately-prefixed physical relay.log lines.
                case("multiline_crlf", function()
                    local ml = "line-a\nline-b\r\nline-c"
                    _print(PREFIX .. " case=multiline_crlf " .. tag .. " " .. ml)
                end)

                -- 5. Literal % / format-looking text: preserved as data (the
                --    native sink never lets Lua bytes become a format string).
                case("percent_fmt", function()
                    _print(PREFIX .. " case=percent_fmt " .. tag .. " 100% done %s %d %%")
                end)

                -- 6. Control/NUL/DEL bytes, constructed safely with string.char.
                --    None are line terminators, so each stays in one physical
                --    line and renders as \xNN in relay.log (NUL cannot terminate
                --    the buffer, DEL/ESC/SOH cannot forge line structure). Note:
                --    the engine's own console print may truncate this line at the
                --    first NUL — that is the engine's unchanged behavior; the
                --    relay.log copy shows the full sanitized bytes.
                case("control_bytes", function()
                    local ctrl = "nul" .. _char(0) .. "soh" .. _char(1) ..
                                 "esc" .. _char(27) .. "del" .. _char(127)
                    _print(PREFIX .. " case=control_bytes " .. tag .. " " .. ctrl)
                end)

                -- 7. Over the 4096-byte native input budget: the case marker is
                --    within the first 4096 bytes, then exactly one truncation
                --    marker follows in relay.log.
                case("over_budget", function()
                    local big = _rep("B", 4200)
                    _print(PREFIX .. " case=over_budget " .. tag .. " begin" .. big .. "end")
                end)

                _pcall(_print, PREFIX .. " SESSION_DONE " .. tag)
                log_line(PREFIX .. " SESSION_DONE " .. tag)
            end,
        }
    end,
}
