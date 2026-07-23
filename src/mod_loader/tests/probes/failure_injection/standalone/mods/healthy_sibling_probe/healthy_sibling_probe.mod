-- healthy_sibling_probe.mod -- manual live diagnostic (not a harness test;
-- not shipped).
--
-- Companion to standalone_failure_probe. A healthy outer entry listed AFTER
-- the failing entry, used to verify that a standalone lifecycle failure does
-- NOT stop an independent sibling: it must visibly init, run a bounded first
-- update (no per-frame spam), and unload cleanly despite the failure injected
-- by the standalone probe in the same generation.
--
-- Output: every event prints a `[HEALTHY_SIBLING]` line to the Darktide
-- console log AND appends+flushes the same line to
-- healthy_sibling_probe/healthy_sibling_probe.log (rooted at the mods dir via
-- Mods.lua.io).
--
-- Install: this folder ships as part of the failure_injection/standalone
-- scenario bundle. Copy mods/healthy_sibling_probe/ into
-- <mod_path>/mods/healthy_sibling_probe/. The bundle's mods.lst already lists
-- `healthy_sibling_probe` after `standalone_failure_probe`.
--
-- Safety: this probe installs no hooks and touches no engine state. Every log
-- write is protected so the probe cannot itself become a failure source.

local _print = print or __print or function() end
local _pcall = pcall
local _type = type

local LOG_PATH = "healthy_sibling_probe/healthy_sibling_probe.log"

-- Best-effort file append: close always runs even when write/flush throws.
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
    _pcall(_print, "[HEALTHY_SIBLING] " .. line)
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

emit("scenario-loaded (healthy sibling of standalone_failure_probe)")

return {
    run = function()
        emit("run")
        local first_update_seen = false
        return {
            init = function(self)
                emit("init (sibling remains alive across standalone failure)")
            end,
            update = function(self, dt)
                -- Bounded: log only the first update so evidence exists that
                -- the sibling is being driven, without per-frame spam.
                if not first_update_seen then
                    first_update_seen = true
                    emit("update bounded-first-update (sibling continues)")
                end
            end,
            on_unload = function(self)
                emit("on_unload")
            end,
        }
    end,
}
