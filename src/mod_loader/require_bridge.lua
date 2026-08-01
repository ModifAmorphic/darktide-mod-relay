-- require_bridge.lua — wraps global require to feed DMF's require store.
--
-- Every successful require of a table result is recorded in Mods.require_store,
-- identity-deduped (a reappearing table is never recorded twice, even
-- non-consecutively). After each successful require the lifecycle coordinator
-- runs (idempotent) to advance class install + boot attachment as main.lua runs.
--
-- Contract: docs/architecture/MOD_LOADER-DMF.md (Surfaces + Deferred bootstrap).

-- Tables aren't hashable by identity in Lua without a proxy, so a linear scan
-- is the correct option (require stores are short per path).
local function identity_seen(list, tbl)
    for i = 1, #list do
        if list[i] == tbl then
            return true
        end
    end
    return false
end

-- Idempotently wrap global require. Repeated calls are no-ops.
local function install_require_bridge()
    if Mods._require_bridge_installed then
        return true
    end
    local original = Mods.original_require
    if type(original) ~= "function" then
        -- Nothing safe to wrap without the captured original; leave global
        -- require alone rather than risk breaking the engine.
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
        -- Advance the coordinator after every successful require (idempotent).
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
