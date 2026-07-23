-- framework_later_probe.mod -- manual live diagnostic (not a harness test;
-- not shipped).
--
-- Companion in the framework_boundary scenario. An outer entry listed AFTER
-- the synthetic `dmf` entry. Its purpose is to make the framework-boundary
-- "skipped" behavior observable: when the synthetic `dmf` entry fails init,
-- Relay stops the load pass, so this later entry must NEVER be run, inited,
-- updated, or unloaded in the failing generation. After recovery it should
-- appear normally.
--
-- Every event prints a `[FB_LATER]` line to the Darktide console log AND
-- appends+flushes the same line to the SHARED scenario log at
-- framework_boundary.log. Per-phase process-global counters accumulate across
-- hot reloads; in the initial failing generation they must all remain at 0.
--
-- Install: this folder ships as part of the failure_injection/framework_boundary
-- scenario bundle. Copy mods/framework_later_probe/ into
-- <mod_path>/mods/framework_later_probe/. The bundle's mods.lst already lists
-- `framework_later_probe` last.
--
-- Safety: this probe installs no hooks and touches no engine state. Every log
-- write is protected so it cannot itself become a failure source.

local _G = _G
local _print = print or __print or function() end
local _pcall = pcall
local _type = type

local SHARED_LOG = "framework_boundary.log"

local CTR = {
    run = "_RELAY_FB_LATER_RUN",
    init = "_RELAY_FB_LATER_INIT",
    update = "_RELAY_FB_LATER_UPDATE",
    unload = "_RELAY_FB_LATER_UNLOAD",
}

local function bump(key)
    if _G[key] == nil then _G[key] = 0 end
    _G[key] = _G[key] + 1
    return _G[key]
end

local function snapshot()
    return "run:" .. (_G[CTR.run] or 0)
        .. " init:" .. (_G[CTR.init] or 0)
        .. " update:" .. (_G[CTR.update] or 0)
        .. " unload:" .. (_G[CTR.unload] or 0)
end

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
    _pcall(_print, "[FB_LATER] " .. line)
    local ok, f = _pcall(function()
        local mods = Mods
        if _type(mods) ~= "table" then return nil end
        local ml = mods.lua
        if _type(ml) ~= "table" then return nil end
        local mio = ml.io
        if _type(mio) ~= "table" then return nil end
        local op = mio.open
        if _type(op) ~= "function" then return nil end
        return op(SHARED_LOG, "a")
    end)
    if not ok or f == nil then
        return
    end
    safe_append(f, "[FB_LATER] " .. line)
end

emit("scenario-loaded counter=" .. snapshot()
    .. " (expected to remain all-zero in a failing framework generation)")

return {
    run = function()
        emit("run counter=" .. snapshot() .. " (after bump run=" .. bump(CTR.run) .. ")")
        local first_update_seen = false
        return {
            init = function(self)
                emit("init counter=" .. snapshot()
                    .. " (after bump init=" .. bump(CTR.init) .. ")")
            end,
            update = function(self, dt)
                if not first_update_seen then
                    first_update_seen = true
                    emit("update bounded-first-update counter=" .. snapshot()
                        .. " (after bump update=" .. bump(CTR.update) .. ")")
                end
            end,
            on_unload = function(self)
                emit("on_unload counter=" .. snapshot()
                    .. " (after bump unload=" .. bump(CTR.unload) .. ")")
            end,
        }
    end,
}
