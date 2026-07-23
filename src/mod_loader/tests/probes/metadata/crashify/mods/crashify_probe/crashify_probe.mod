-- crashify_probe.mod -- manual live diagnostic (not a harness test; not shipped).
--
-- Outer-driven probe for the per-mod Crashify metadata feature. Once per
-- loaded generation (after a short update delay so engine registration has
-- settled) it:
--   * feature-detects Crashify.print_property, remove_print_property, and
--     get_print_property and logs each one's availability (function / nil /
--     other) without calling the publication paths;
--   * reads back ModRelay:Version, Mod:crashify_alpha, Mod:crashify_beta, and
--     Mod:crashify_probe via Crashify.get_print_property when available; and
--   * labels the whole pass with a process-global run counter so the initial
--     load and each hot reload are distinguishable in the log.
--
-- Output: each event prints a `[CRASHIFY_PROBE]` line to the Darktide console
-- log AND appends+flushes the same line to crashify_probe/crashify_probe.log
-- (rooted at the mods dir via Mods.lua.io). Append mode accumulates across
-- sessions and reloads; the run counter disambiguates overlapping runs.
--
-- Install: this folder ships as part of the metadata/crashify scenario bundle.
-- Copy mods/crashify_probe/ into <mod_path>/mods/crashify_probe/ and list
-- `crashify_probe` in <mod_path>/mods/mods.lst (the bundle's mods.lst already
-- does, last so alpha/beta are accepted before this probe observes).
--
-- Safety: this probe is read-only with respect to engine and Crashify state.
-- Every Crashify lookup, call, formatting step, and file write is protected so
-- the probe itself cannot trip Relay's outer-failure containment. A missing
-- Crashify, a missing method, or a throwing getter degrades to a clear
-- `<...>` placeholder marker, never an error.

local _G = _G
local _print = print or __print or function() end
local _tostring = tostring
local _pcall = pcall
local _type = type
local _rawget = rawget
local _ipairs = ipairs
local _concat = table.concat

-- Process-global run counter. Bumped once per .mod execution (initial load +
-- each hot reload). Survives hot reload because _G is process-lifetime; does
-- not survive process restart. Labels each generation's observation pass.
if _G._RELAY_CRASHIFY_PROBE_RUN == nil then
    _G._RELAY_CRASHIFY_PROBE_RUN = 0
end
_G._RELAY_CRASHIFY_PROBE_RUN = _G._RELAY_CRASHIFY_PROBE_RUN + 1
local run_label = _G._RELAY_CRASHIFY_PROBE_RUN

local LOG_PATH = "crashify_probe/crashify_probe.log"

-- Best-effort file append: write and flush are attempted, and close ALWAYS runs
-- (even when write/flush throws) so a throwing write can never leak a handle.
-- Every step is individually pcall'd; a throwing step degrades to a no-op.
local function safe_append(f, file_line)
    local write_ok = _pcall(function() f:write(file_line .. "\n") end)
    if write_ok and _type(f.flush) == "function" then
        _pcall(f.flush, f)
    end
    if _type(f.close) == "function" then
        _pcall(f.close, f)
    end
end

-- Protected scenario-log append. Every step is pcall'd: a missing Mods.lua.io
-- chain, a throwing open/write/flush, or a missing flush method degrades to a
-- silent no-op so the probe cannot become a failure source.
local function emit(line)
    _pcall(_print, "[CRASHIFY_PROBE] " .. line)
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

-- Fetch the global Crashify table without ever raising.
local function crashify_table()
    local ok, c = _pcall(function() return _rawget(_G, "Crashify") end)
    if ok and _type(c) == "table" then
        return c
    end
    return nil
end

-- Describe one Crashify method's availability without invoking it.
local function method_kind(c, name)
    if c == nil then
        return "no-Crashify"
    end
    local ok, m = _pcall(function() return c[name] end)
    if not ok then
        return "lookup-error"
    end
    return _type(m)
end

-- Read one published crash property via get_print_property; never raises.
-- Both the getter LOOKUP and the getter CALL are protected: a Crashify table
-- with a throwing __index metamethod must not break the probe.
local function read_key(c, key)
    if c == nil then
        return "<no-Crashify>"
    end
    local gok, getter = _pcall(function() return c.get_print_property end)
    if not gok or _type(getter) ~= "function" then
        return "<no-get_print_property>"
    end
    local ok, value = _pcall(getter, key)
    if not ok then
        return "<read-error>"
    end
    if value == nil then
        return "<absent>"
    end
    local rok, text = _pcall(_tostring, value)
    if rok and _type(text) == "string" then
        return text
    end
    return "<unprintable>"
end

emit("scenario-loaded generation-label=#" .. run_label
    .. " (Relay crashify metadata probe)")

return {
    run = function()
        emit("run generation-label=#" .. run_label)
        local observed = false
        local clock = 0
        return {
            init = function(self)
                emit("init generation-label=#" .. run_label)
            end,
            update = function(self, dt)
                if observed then
                    return
                end
                if _type(dt) == "number" and dt > 0 then
                    clock = clock + dt
                end
                -- Short update delay so engine crash-property registration has
                -- settled before read-back. ~0.1s = a handful of frames.
                if clock < 0.1 then
                    return
                end
                observed = true
                local c = crashify_table()
                local parts = {
                    "observe generation-label=#" .. run_label,
                    "print_property=" .. method_kind(c, "print_property"),
                    "remove_print_property=" .. method_kind(c, "remove_print_property"),
                    "get_print_property=" .. method_kind(c, "get_print_property"),
                }
                local keys = {
                    "ModRelay:Version",
                    "Mod:crashify_alpha",
                    "Mod:crashify_beta",
                    "Mod:crashify_probe",
                }
                for _, k in _ipairs(keys) do
                    parts[#parts + 1] = k .. "=" .. read_key(c, k)
                end
                emit(_concat(parts, " | "))
            end,
            on_unload = function(self)
                emit("on_unload generation-label=#" .. run_label)
            end,
        }
    end,
}
