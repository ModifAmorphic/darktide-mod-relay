-- class_registry.lua — CLASS registry + the sole _G[class_name] write surface.
--
-- Wraps the engine's global `class` so every result is recorded in CLASS[name]
-- and mirrored to _G[name] (rawget-guarded). Owns BOTH directions of the
-- _G[class_name] surface — register (class()) and clear (retire_class, which
-- does NOT clear CLASS[name]); retirement must route through retire_class.
--
-- Sentinel + globalization rationale: docs/architecture/MOD_LOADER-DMF.md.

-- CLASS is created up front if absent. If the engine (or a prior pass) already
-- populated it, keep what's there.
CLASS = CLASS or {}

-- Attach the unresolved-class sentinel if CLASS has no metatable yet (don't
-- clobber an engine-provided one). __index returns a missing key as a string so
-- DMF's string/table hook validator accepts it; registered entries are returned
-- directly (metatable not consulted for existing keys). Writes unaffected (no
-- __newindex).
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

-- Idempotently install the class wrapper. Returns true once installed, false
-- when global `class` is absent/not a function (not-ready: no mutation until it
-- appears).
local function install_class_registry()
    if installed then return true end
    local c = _rawget(_G, "class")
    if type(c) ~= "function" then
        return false
    end
    original_class = c
    installed = true
    -- Stores the result in CLASS[name] and publishes to _G[name] when not
    -- already set (rawget-guarded so engine/DMF explicit assignments are
    -- preserved). Super/varargs forwarded exactly. The CLASS write is direct
    -- (the __index sentinel only affects missing-key reads).
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

-- Clear a single class result from _G. Does NOT clear CLASS[name] — new
-- class() calls overwrite CLASS entries normally
-- (see docs/architecture/MOD_LOADER-DMF.md).
local function retire_class(name)
    if type(name) ~= "string" then return end
    _G[name] = nil
end

Mods.install_class_registry = install_class_registry
Mods.retire_class = retire_class
