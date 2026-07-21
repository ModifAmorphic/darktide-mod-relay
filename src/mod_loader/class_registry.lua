-- class_registry.lua — CLASS registry + the sole _G[class_name] write surface.
--
-- Wraps the engine's global `class` so every result is recorded in CLASS[name]
-- (the loader's authoritative handle on engine state classes, which are not
-- bare _G globals) and published to _G[name] for mod compatibility. This module
-- owns BOTH directions of the _G[class_name] surface — every register (class())
-- AND every clear (retire_class) — so dmf_adapter and any other consumer routes
-- class-result retirement through retire_class rather than writing _G directly.
-- retire_class does NOT clear CLASS[name]; new class() calls overwrite CLASS
-- entries normally.
--
-- Unresolved-class sentinel + globalization rationale:
-- docs/architecture/MOD_LOADER-DMF.md.

-- CLASS is created up front if absent. If the engine (or a prior pass) already
-- populated it, keep what's there.
CLASS = CLASS or {}

-- Attach the unresolved-class sentinel if CLASS has no metatable yet (don't
-- clobber an engine-provided one). __index returns the missing key as a string
-- so DMF's string/table hook validator accepts it; registered entries live in
-- the table itself and are returned directly (the metatable is not consulted
-- for keys that exist). Writes are unaffected (no __newindex).
if getmetatable(CLASS) == nil then
    setmetatable(CLASS, {
        __index = function(_, key)
            return key
        end,
    })
end

local _rawget = rawget
local _print = __print or print

local installed = false
local original_class = nil

-- Idempotently install the class wrapper. Returns true once installed (or if
-- already installed), false when global `class` is absent or not a function
-- (the not-ready case — no mutation happens until it appears).
local function install_class_registry()
    if installed then return true end
    local c = _rawget(_G, "class")
    if type(c) ~= "function" then
        return false
    end
    original_class = c
    installed = true
    -- Replace _G.class with a closure that delegates to the captured original,
    -- stores the returned class object in CLASS[name] and (when not already
    -- set) publishes it to _G[name] for the community contract, and returns it
    -- verbatim. Super/varargs are forwarded exactly. The CLASS store is a
    -- direct table write (the __index sentinel only affects missing-key
    -- reads); the _G write is rawget-guarded so engine/DMF explicit
    -- assignments are preserved.
    _G.class = function(name, ...)
        local result = original_class(name, ...)
        if type(name) == "string" then
            CLASS[name] = result
            if _rawget(_G, name) == nil then
                _G[name] = result
            end
        end
        return result
    end
    return true
end

-- Clear a single class result from _G. Sole owner of the _G[class_name]
-- write surface: every register AND every clear goes through here.
-- Does NOT clear CLASS[name] — new class() calls overwrite CLASS entries
-- normally (see docs/architecture/MOD_LOADER-DMF.md).
local function retire_class(name)
    if type(name) ~= "string" then return end
    _G[name] = nil
end

Mods.install_class_registry = install_class_registry
Mods.retire_class = retire_class
