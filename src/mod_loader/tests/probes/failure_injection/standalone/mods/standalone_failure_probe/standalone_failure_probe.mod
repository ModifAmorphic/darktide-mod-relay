-- standalone_failure_probe.mod -- manual live diagnostic (not a harness test;
-- not shipped).
--
-- Standalone outer-entry FAILURE-INJECTION probe. Reads a staged mode file to
-- choose between an injected first-update error (fail) and a healthy bounded
-- first update (healthy). Ships mode.txt initially set to "fail"; copy the
-- supplied mode-healthy.txt over it to recover. No code editing required.
--
-- Behavior:
--   * fail mode  — the first update logs entry, then raises a neutral
--                  Relay-owned scratch error. Relay's outer-failure
--                  containment must then disable this entry for the rest of
--                  the generation (no retry) and call on_unload exactly once.
--   * healthy    — logs init and a bounded first update only; no error and no
--                  per-frame spam.
--
-- Process-global counters (updates in fail mode, unloads) make any prohibited
-- retry or double-unload visible in the log and via `_G` inspection.
--
-- Output: every event prints a `[STANDALONE_FAILURE]` line to the Darktide
-- console log AND appends+flushes the same line to
-- standalone_failure_probe/standalone_failure_probe.log (rooted at the mods
-- dir via Mods.lua.io). Append mode accumulates across reloads; the counters
-- disambiguate each phase.
--
-- Install: this folder ships as part of the failure_injection/standalone
-- scenario bundle. Copy mods/standalone_failure_probe/ into
-- <mod_path>/mods/standalone_failure_probe/ and keep mode.txt alongside the
-- .mod. The bundle's mods.lst already lists `standalone_failure_probe` first.
--
-- Safety: this probe INTENTIONALLY raises one error in fail mode (that is the
-- behavior under test). Every other operation — mode-file read, log write,
-- counter bookkeeping — is protected so the probe cannot trip containment for
-- any reason other than the intended injected failure. It installs no hooks
-- and touches no engine state.

local _G = _G
local _print = print or __print or function() end
local _pcall = pcall
local _type = type
local _error = error

-- Process-global counters. Survive hot reload (_G is process-lifetime); do not
-- survive process restart. The fail-mode update counter freezes at 1 when
-- containment works; >1 means Relay retried a disabled callback (a bug).
-- The unload counter reflects total teardown entries across the process.
if _G._RELAY_STANDALONE_FAIL_UPDATES == nil then
    _G._RELAY_STANDALONE_FAIL_UPDATES = 0
end
if _G._RELAY_STANDALONE_FAIL_UNLOADS == nil then
    _G._RELAY_STANDALONE_FAIL_UNLOADS = 0
end

local LOG_PATH = "standalone_failure_probe/standalone_failure_probe.log"
local MODE_PATH = "standalone_failure_probe/mode.txt"

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

-- Protected scenario-log append: a missing Mods.lua.io chain or a throwing
-- open/write/flush degrades to a silent no-op so logging cannot itself trip
-- containment.
local function emit(line)
    _pcall(_print, "[STANDALONE_FAILURE] " .. line)
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

-- Read+trim the staged mode file. Never raises; returns "missing" on any
-- failure so the probe degrades to a clearly-labeled no-op rather than an
-- unintended error path.
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
emit("scenario-loaded mode=" .. mode
    .. " counter=updates:" .. _G._RELAY_STANDALONE_FAIL_UPDATES
    .. " unloads:" .. _G._RELAY_STANDALONE_FAIL_UNLOADS)

return {
    run = function()
        emit("run mode=" .. mode)
        local fail_failure_injected = false
        local healthy_first_seen = false
        return {
            init = function(self)
                emit("init mode=" .. mode)
            end,
            update = function(self, dt)
                if mode == "fail" then
                    -- Fail-mode updates are the dangerous path the counter
                    -- tracks. Containment must stop this after the first.
                    _G._RELAY_STANDALONE_FAIL_UPDATES =
                        _G._RELAY_STANDALONE_FAIL_UPDATES + 1
                    emit("update mode=fail"
                        .. " counter=updates:" .. _G._RELAY_STANDALONE_FAIL_UPDATES
                        .. " unloads:" .. _G._RELAY_STANDALONE_FAIL_UNLOADS)
                    if not fail_failure_injected then
                        fail_failure_injected = true
                        emit("update raising injected scratch error"
                            .. " (Relay should disable this entry now)")
                        -- Neutral Relay-owned scratch error. Relay formats
                        -- this with a traceback in its own diagnostic line.
                        _error("[standalone_failure_probe] injected update failure")
                    end
                elseif mode == "healthy" then
                    if not healthy_first_seen then
                        healthy_first_seen = true
                        emit("update mode=healthy bounded-first-update"
                            .. " counter=updates:" .. _G._RELAY_STANDALONE_FAIL_UPDATES
                            .. " unloads:" .. _G._RELAY_STANDALONE_FAIL_UNLOADS)
                    end
                else
                    if not healthy_first_seen then
                        healthy_first_seen = true
                        emit("update mode=" .. mode .. " bounded-first-update"
                            .. " (unexpected mode; treating as healthy)")
                    end
                end
            end,
            on_unload = function(self)
                _G._RELAY_STANDALONE_FAIL_UNLOADS =
                    _G._RELAY_STANDALONE_FAIL_UNLOADS + 1
                emit("on_unload mode=" .. mode
                    .. " counter=updates:" .. _G._RELAY_STANDALONE_FAIL_UPDATES
                    .. " unloads:" .. _G._RELAY_STANDALONE_FAIL_UNLOADS)
            end,
        }
    end,
}
