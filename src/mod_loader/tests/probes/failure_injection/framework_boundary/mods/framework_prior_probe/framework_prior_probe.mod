-- framework_prior_probe.mod -- manual live diagnostic (not a harness test;
-- not shipped).
--
-- Companion in the framework_boundary scenario. An outer entry listed BEFORE
-- the synthetic `dmf` entry. Its purpose is to make the framework-boundary
-- failure sequence observable: when the synthetic `dmf` entry fails init,
-- this prior entry must already have initialized; on the framework stop it
-- must be unloaded in REVERSE load order (after the `dmf` entry); and it must
-- NOT receive any update callback in the stopped generation.
--
-- Output: every event prints a `[FB_PRIOR]` line to the Darktide console log
-- AND appends+flushes the same line to the SHARED scenario log at
-- framework_boundary.log (rooted at the mods dir via Mods.lua.io, i.e. a
-- sibling of the three probe folders). Process-global per-phase counters
-- (run/init/update/unload) accumulate across hot reloads so a full
-- fail-then-recover cycle is readable from a single log.
--
-- Install: this folder ships as part of the failure_injection/framework_boundary
-- scenario bundle. Copy mods/framework_prior_probe/ into
-- <mod_path>/mods/framework_prior_probe/. The bundle's mods.lst already lists
-- `framework_prior_probe` first.
--
-- Safety: this probe installs no hooks and touches no engine state. Every log
-- write is protected so it cannot itself become a failure source.

local _G = _G
local _print = print or __print or function() end
local _pcall = pcall
local _type = type

local SHARED_LOG = "framework_boundary.log"

-- Per-phase process-global counters (survive hot reload; reset on process
-- restart). Named per probe so all three are individually inspectable.
local CTR = {
    run = "_RELAY_FB_PRIOR_RUN",
    init = "_RELAY_FB_PRIOR_INIT",
    update = "_RELAY_FB_PRIOR_UPDATE",
    unload = "_RELAY_FB_PRIOR_UNLOAD",
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
    _pcall(_print, "[FB_PRIOR] " .. line)
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
    safe_append(f, "[FB_PRIOR] " .. line)
end

emit("scenario-loaded counter=" .. snapshot())

return {
    run = function()
        emit("run counter=" .. snapshot() .. " (after bump run=" .. bump(CTR.run) .. ")")
        local first_update_seen = false
        return {
            init = function(self)
                emit("init counter=" .. snapshot() .. " (after bump init=" .. bump(CTR.init) .. ")")
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
