-- shutdown_probe.mod -- manual live diagnostic (not a harness test; not shipped).
--
-- An outer-driven mod that records the loader's public lifecycle-callback
-- sequence (on_game_state_changed / on_reload / on_unload, plus init) to a log
-- file and the console. Use it to observe state-exit / reload / unload ordering
-- in the real game (e.g. verifying the final state-exit fires on shutdown).
--
-- Install: copy to <mod_path>/mods/shutdown_probe/shutdown_probe.mod and add a
-- `shutdown_probe` line to mods.lst. Launch, exercise the scenario, exit.
--
-- Output: each callback appends one line to shutdown_probe/shutdown_probe.log
-- (via Mods.lua.io.open, rooted at the mods dir) AND prints a [SHUTDOWN_PROBE]
-- line to the console log. A monotonic #n preserves ordering.

local _print = print or __print or function() end
local _tostring = tostring
local _select = select
local _concat = table.concat

local seq = 0

local function emit(line)
    _print("[SHUTDOWN_PROBE] " .. line)
    local f = Mods.lua.io.open("shutdown_probe/shutdown_probe.log", "a")
    if f then
        f:write(line .. "\n")
        if f.flush then f:flush() end
        if f.close then f:close() end
    end
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
