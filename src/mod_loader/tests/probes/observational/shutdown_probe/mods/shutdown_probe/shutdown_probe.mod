-- shutdown_probe.mod -- manual live diagnostic (not a harness test; not shipped).
--
-- An outer-driven mod that records the loader's public lifecycle-callback
-- sequence (on_game_state_changed / on_reload / on_unload, plus init) to a log
-- file and the console. Use it to observe state-exit / reload / unload ordering
-- in the real game (e.g. verifying the final state-exit fires on shutdown).
--
-- Install: this scenario ships a complete bundle — its directory is itself the
-- <mod_path>. Launch directly with
--   --mod-path <path-to-observational/shutdown_probe>
-- (the bundle's mods/mods.lst already lists exactly `shutdown_probe`). See
-- README.md in the scenario root for the full launch/staging, expected evidence,
-- and cleanup.
--
-- Output: each callback appends one line to shutdown_probe/shutdown_probe.log
-- (via Mods.lua.io.open, rooted at the mods dir) AND prints a [SHUTDOWN_PROBE]
-- line to the console log. A monotonic #n preserves ordering.

local _print = print or __print or function() end
local _tostring = tostring
local _select = select
local _concat = table.concat
local _pcall = pcall
local _type = type

local seq = 0

local LOG_PATH = "shutdown_probe/shutdown_probe.log"

-- Best-effort file append: write and flush are attempted, and close ALWAYS runs
-- (even when write/flush throws) so a throwing write can never leak a handle.
local function safe_append(f, file_line)
    local write_ok = _pcall(function() f:write(file_line .. "\n") end)
    if write_ok and _type(f.flush) == "function" then
        _pcall(f.flush, f)
    end
    if _type(f.close) == "function" then
        _pcall(f.close, f)
    end
end

local function emit(line)
    _pcall(_print, "[SHUTDOWN_PROBE] " .. line)
    local ok, f = _pcall(function()
        local mods = Mods
        if _type(mods) ~= "table" then return nil end
        local ml = mods.lua
        if _type(ml) ~= "table" then return nil end
        local mio = ml.io
        if _type(mio) ~= "table" then return nil end
        local op = mio.open
        if _type(op) ~= "function" then return nil end
        return op(LOG_PATH, "a")
    end)
    if not ok or f == nil then
        return
    end
    safe_append(f, line)
end

local function record(tag, ...)
    seq = seq + 1
    local parts = { "#" .. seq, tag }
    local n = _select("#", ...)
    for i = 1, n do
        parts[#parts + 1] = _tostring(_select(i, ...))
    end
    emit(_concat(parts, " | "))
end

return {
    run = function()
        -- SESSION_START marks one process/load; use it to align log lines to a
        -- run when several sessions accumulate in the same file (append mode).
        record("SESSION_START", "run")
        return {
            init = function(self)
                record("init")
            end,
            on_game_state_changed = function(self, status, state_name, state_object)
                record("on_game_state_changed",
                    "status=" .. _tostring(status),
                    "state_name=" .. _tostring(state_name),
                    "state_object=" .. _tostring(state_object))
            end,
            on_reload = function(self)
                record("on_reload")
            end,
            on_unload = function(self)
                record("on_unload")
            end,
        }
    end,
}
