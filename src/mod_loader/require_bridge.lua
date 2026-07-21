-- require_bridge.lua — wraps global require to feed DMF's require store.
--
-- DMF's core/require.lua consumes two surfaces off Mods:
--   - Mods.original_require  (the pre-wrap engine require; captured by init)
--   - Mods.require_store[path]  (an ordered array of distinct table instances
--     returned by engine require for that path; DMF's hook_require applies
--     file hooks to each instance)
--
-- This module wraps global require (idempotently) so that every successful
-- require of a table result is recorded in the store. Recording is by table
-- IDENTITY, not consecutive-equality: if the same table reappears (even
-- non-consecutively, interleaved with other requires) it is not recorded
-- twice. Non-table results are not cached.
--
-- After every successful require, the lifecycle bootstrap coordinator is
-- called so class installation and boot attachment advance as main.lua runs.

-- Linear identity scan. Returns true if `tbl` is already in `list` (by
-- reference equality). A small private set keyed by the table would also work,
-- but tables aren't hashable by identity in Lua without a proxy, so a scan is
-- the simple correct option (require stores are short per path).
local function identity_seen(list, tbl)
    for i = 1, #list do
        if list[i] == tbl then
            return true
        end
    end
    return false
end

-- Idempotently wrap global require. The original (Mods.original_require) is
-- retained; repeated calls are no-ops.
local function install_require_bridge()
    if Mods._require_bridge_installed then
        return true
    end
    local original = Mods.original_require
    if type(original) ~= "function" then
        -- Without the captured original there is nothing safe to wrap; leave
        -- global require alone rather than risk breaking the engine.
        return false
    end
    Mods.require_store = Mods.require_store or {}
    Mods._require_bridge_installed = true

    local function wrapped_require(path, ...)
        local result = original(path, ...)
        if type(result) == "table" then
            local store = Mods.require_store
            local list = store[path]
            if not list then
                list = {}
                store[path] = list
            end
            if not identity_seen(list, result) then
                list[#list + 1] = result
            end
        end
        -- Advance the lifecycle coordinator after every successful require so
        -- class installation + boot attachment happen as soon as the engine
        -- makes them possible. The coordinator is idempotent.
        local coord = Mods.coordinate_bootstrap
        if type(coord) == "function" then
            coord()
        end
        return result
    end

    _G.require = wrapped_require
    return true
end

Mods.install_require_bridge = install_require_bridge
