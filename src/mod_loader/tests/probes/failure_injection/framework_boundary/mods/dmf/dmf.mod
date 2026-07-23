-- dmf.mod -- manual live diagnostic; SYNTHETIC Relay-owned probe (NOT stock DMF).
--
-- This descriptor intentionally owns the folder/name "dmf" so that Relay's
-- framework-boundary containment path applies to it. It is NOT stock DMF and
-- does NOT reproduce any DMF behavior: it does not install hooks, does not
-- register mods, does not touch DMF internals, and does not mutate engine
-- state. It is purely an outer object that fails init in fail mode (the
-- behavior under test) and runs normally in healthy mode.
--
-- Reads a staged mode file: mode.txt (initially "fail") chooses the injected
-- init failure; mode-healthy.txt is supplied for recovery (copy over mode.txt
-- then hot reload — no code editing).
--
-- Output: every event prints a `[FB_DMF]` line to the Darktide console log AND
-- appends+flushes the same line to the SHARED scenario log at
-- framework_boundary.log (rooted at the mods dir via Mods.lua.io, i.e. a
-- sibling of the three probe folders). Per-phase process-global counters
-- (run/init/update/unload) accumulate across hot reloads.
--
-- Install: this folder ships as part of the failure_injection/framework_boundary
-- scenario bundle. Copy mods/dmf/ into <mod_path>/mods/dmf/ and keep mode.txt
-- alongside the .mod. The bundle's mods.lst already lists `dmf` in the middle.
--
-- Safety: this probe INTENTIONALLY raises one error in fail mode (that is the
-- behavior under test). Every other operation — mode-file read, log write,
-- counter bookkeeping — is protected. It installs no hooks and touches no
-- engine state. Do NOT overlay this scenario onto a normal stock-DMF profile:
-- stage it only into an empty isolated mod root.

local _G = _G
local _print = print or __print or function() end
local _pcall = pcall
local _type = type
local _error = error

local SHARED_LOG = "framework_boundary.log"
local MODE_PATH = "dmf/mode.txt"

local CTR = {
    run = "_RELAY_FB_DMF_RUN",
    init = "_RELAY_FB_DMF_INIT",
    update = "_RELAY_FB_DMF_UPDATE",
    unload = "_RELAY_FB_DMF_UNLOAD",
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
    _pcall(_print, "[FB_DMF] " .. line)
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
    safe_append(f, "[FB_DMF] " .. line)
end

-- Protected mode-file read. Returns "missing" on any failure so the probe
-- degrades to a clearly-labeled no-op rather than an unintended error path.
local function read_mode()
    local ok, f = _pcall(function()
        local mods = Mods
        if _type(mods) ~= "table" then return nil end
        local ml = mods.lua
        if _type(ml) ~= "table" then return nil end
        local mio = ml.io
        if _type(mio) ~= "table" then return nil end
        local op = mio.open
        if _type(op) ~= "function" then return nil end
        return op(MODE_PATH, "r")
    end)
    if not ok or f == nil then
        return "missing"
    end
    local content = ""
    _pcall(function()
        content = f:read("*all") or ""
        if _type(f.close) == "function" then f:close() end
    end)
    content = content:gsub("^%s+", ""):gsub("%s+$", "")
    return content
end

local mode = read_mode()
emit("scenario-loaded mode=" .. mode .. " counter=" .. snapshot()
    .. " (SYNTHETIC probe; not stock DMF)")

return {
    run = function()
        emit("run counter=" .. snapshot() .. " (after bump run=" .. bump(CTR.run) .. ")")
        local healthy_first_seen = false
        return {
            init = function(self)
                emit("init counter=" .. snapshot()
                    .. " (after bump init=" .. bump(CTR.init) .. ")")
                if mode == "fail" then
                    emit("init raising injected framework-boundary scratch error"
                        .. " (Relay should stop the current generation)")
                    -- Neutral Relay-owned scratch error. Because this entry's
                    -- name is exactly "dmf", Relay's framework-boundary path
                    -- applies: it stops all outer driving for the generation,
                    -- skips later entries, and reverse-unloads active objects.
                    _error("[framework_boundary/dmf] injected init failure")
                end
            end,
            update = function(self, dt)
                -- Bounded: log only the first update so evidence exists that
                -- the framework object is being driven, without per-frame spam.
                if not healthy_first_seen then
                    healthy_first_seen = true
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
