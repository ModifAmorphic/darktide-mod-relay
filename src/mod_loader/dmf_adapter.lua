-- dmf_adapter.lua — the stock-DMF compatibility boundary for the mod loader.
--
-- A plain Lua module (NOT an engine class(), NOT a proxy/metatable facade) that
-- centralizes every stock-DMF-specific assumption the loader makes, so
-- mod_manager.lua can stay generic: scan/order/load/drive/unload/isolate/reload.
-- Loaded from the loader root via Mods.load_module("dmf_adapter") at the top of
-- mod_manager.lua; the factory M.new(manager) returns one adapter per manager.
--
-- Full contract — DMF-visible field transitions, the generation-aware IO
-- adaptation mechanism, the reload teardown boundary — is documented in
-- docs/architecture/MOD_LOADER-DMF.md.

local _type = type
local _rawget = rawget

local M = {}

-- Build a mod-relative path from DMF's io_* argument shape, replicating DMF's
-- get_file_path joining (minus its hardcoded "./../mods" base). local_path is
-- the directory portion, file_name the file, file_extension the extension
-- (defaults to "lua" when absent — matching DMF).
local function build_dmf_path(local_path, file_name, file_extension)
    local p = ""
    if local_path and local_path ~= "" then
        p = local_path
    end
    if file_name and file_name ~= "" then
        if p == "" then
            p = file_name
        else
            p = p .. "/" .. file_name
        end
    end
    if file_extension and file_extension ~= "" then
        return p .. "." .. file_extension
    end
    return p .. ".lua"
end

-- Validate a _mods entry has the shape DMF requires at the load boundary:
-- non-nil `id`, string `name`, non-nil `handle`. Returns (true) on success or
-- (false, reason) on failure. Generic _mods ownership/scanning stays in
-- mod_manager.lua; this only centralizes the DMF-required shape check.
local function validate_entry_shape(entry)
    if entry == nil then
        return false, "missing entry"
    end
    if entry.id == nil then
        return false, "missing id"
    end
    if _type(entry.name) ~= "string" then
        return false, "name not a string"
    end
    if entry.handle == nil then
        return false, "missing handle"
    end
    return true
end

-- Restore persisted manager settings from Application.user_setting; startup-only
-- with a defensive { developer_mode = false } fallback. See MOD_LOADER-DMF.md
-- for the persisted-developer-mode policy.
local function restore_persisted_settings()
    local app = _rawget(_G, "Application")
    if _type(app) == "table" and _type(app.user_setting) == "function" then
        local ok, settings = pcall(function()
            return app.user_setting("mod_manager_settings")
        end)
        if ok and _type(settings) == "table" then
            if _type(settings.developer_mode) ~= "boolean" then
                settings.developer_mode = false
            end
            return settings
        end
    end
    return { developer_mode = false }
end

-- Factory: bind an adapter to one manager instance. Private state lives in
-- closure upvalues (see adapt_dmf_io and retire_stale_generation_globals);
-- only the explicit transition methods write DMF-visible contract fields.
function M.new(manager)
    local observer_registered = false
    local adapted_dmfmod = nil
    local adapted_io_dofile = nil

    -- Adapt DMF's mod-facing io_* methods to delegate to Mods.file.* (mod-root
    -- rooted). Installation-aware idempotent — see MOD_LOADER-DMF.md.
    local function adapt_dmf_io()
        local DMFMod = _rawget(_G, "DMFMod")
        if _type(DMFMod) ~= "table" then
            return
        end
        -- Idempotence requires BOTH the table identity AND our installed
        -- wrapper to still be current. A same table whose io_dofile was
        -- overwritten must fall through and re-adapt.
        if DMFMod == adapted_dmfmod and DMFMod.io_dofile == adapted_io_dofile then
            return
        end
        -- Wait for a function surface to adapt (core/io.lua not yet run for a
        -- fresh table, or the table predates any method install).
        if _type(DMFMod.io_dofile) ~= "function" then
            return
        end

        local file = Mods.file

        -- Emit a DMF debug line if the mod object exposes :debug().
        local function dmf_debug(self_dmf, msg)
            local dbg = self_dmf.debug
            if _type(dbg) == "function" then
                dbg(self_dmf, msg)
            end
        end

        -- Emit a DMF error line if the mod object exposes :error().
        local function dmf_error(self_dmf, msg)
            local errf = self_dmf.error
            if _type(errf) == "function" then
                errf(self_dmf, msg)
            end
        end

        -- Drive a SAFE Relay file op with DMF debug/error logging. Logs
        -- "Loading <rel>" before; on a false result, logs a concise error
        -- naming <rel>. Returns the Relay result unchanged.
        local function safe_io(self_dmf, rel, file_op, ...)
            dmf_debug(self_dmf, "Loading " .. rel)
            local result = file_op(rel, ...)
            if result == false then
                dmf_error(self_dmf, "Error loading '" .. rel .. "'")
            end
            return result
        end

        -- Drive an UNSAFE Relay file op with DMF debug logging only. The op
        -- may raise; the debug line is emitted before, and the error is not
        -- swallowed.
        local function unsafe_io(self_dmf, rel, file_op, ...)
            dmf_debug(self_dmf, "Loading " .. rel)
            return file_op(rel, ...)
        end

        -- io_dofile / io_dofile_unsafe take a single path (extension defaults lua).
        DMFMod.io_dofile = function(self_dmf, file_path)
            return safe_io(self_dmf, build_dmf_path(file_path, nil, nil), file.dofile)
        end
        DMFMod.io_dofile_unsafe = function(self_dmf, file_path)
            return unsafe_io(self_dmf, build_dmf_path(file_path, nil, nil), file.dofile_unsafe)
        end
        -- io_exec / io_exec_unsafe variants take (local_path, file_name,
        -- file_extension, args).
        DMFMod.io_exec = function(self_dmf, local_path, file_name, file_extension, args)
            return safe_io(self_dmf, build_dmf_path(local_path, file_name, file_extension), file.exec, args)
        end
        DMFMod.io_exec_unsafe = function(self_dmf, local_path, file_name, file_extension, args)
            return unsafe_io(self_dmf, build_dmf_path(local_path, file_name, file_extension), file.exec_unsafe, args)
        end
        DMFMod.io_exec_with_return = function(self_dmf, local_path, file_name, file_extension, args)
            return safe_io(self_dmf, build_dmf_path(local_path, file_name, file_extension), file.exec_with_return, args)
        end
        DMFMod.io_exec_unsafe_with_return = function(self_dmf, local_path, file_name, file_extension, args)
            return unsafe_io(self_dmf, build_dmf_path(local_path, file_name, file_extension), file.exec_unsafe_with_return, args)
        end
        -- io_read_content / io_read_content_to_table take (file_path, file_extension).
        DMFMod.io_read_content = function(self_dmf, file_path, file_extension)
            return safe_io(self_dmf, build_dmf_path(file_path, nil, file_extension), file.read_content)
        end
        DMFMod.io_read_content_to_table = function(self_dmf, file_path, file_extension)
            return safe_io(self_dmf, build_dmf_path(file_path, nil, file_extension), file.read_content_to_table)
        end

        -- Record BOTH the table identity and the exact Relay wrapper we just
        -- installed, so a later overwrite of these methods on the same table
        -- (core/io.lua) is detected and re-adapted rather than silently kept.
        adapted_dmfmod = DMFMod
        adapted_io_dofile = DMFMod.io_dofile
    end

    return {
        -- Establish the DMF-visible contract: publish Managers.mod and initialize
        -- _settings (restored from persistence once at startup), _state, _mod_load_index.
        establish = function(self)
            Managers = Managers or {}
            Managers.mod = manager
            -- _settings restoration is startup-only; identity preserved on re-call.
            if manager._settings == nil then
                manager._settings = restore_persisted_settings()
            end
            manager._state = nil
            manager._mod_load_index = nil
        end,

        -- Register the DMF IO observer on Mods.file exactly once; safely re-fires per exec.
        register_io_observer = function(self)
            if observer_registered then
                return
            end
            if _type(Mods.file) ~= "table"
               or _type(Mods.file.add_observer) ~= "function" then
                return
            end
            Mods.file.add_observer(function()
                adapt_dmf_io()
            end)
            observer_registered = true
        end,

        begin_load_entry = function(self, idx)
            manager._mod_load_index = idx
        end,
        end_load_pass = function(self)
            manager._mod_load_index = nil
        end,
        mark_load_done = function(self)
            manager._state = "done"
        end,
        mark_load_pending = function(self)
            manager._state = nil
        end,

        is_load_done = function(self)
            return manager._state == "done"
        end,
        developer_mode_enabled = function(self)
            return manager._settings ~= nil
                and manager._settings.developer_mode == true
        end,

        -- Validate a _mods entry has the DMF-required shape at the load
        -- boundary. Returns (true) | (false, reason). Pure check; the manager
        -- decides what to do on failure (skip + log).
        validate_entry = function(self, entry)
            return validate_entry_shape(entry)
        end,

        -- Reload-teardown retirement, split by ownership: class results
        -- (DMFMod) route through class_registry (Mods.retire_class) since it
        -- owns the _G[class_name] surface; DMF installation helpers
        -- (new_mod/get_mod, not classes) stay local. Retains the private
        -- adapted_dmfmod + adapted_io_dofile markers. See MOD_LOADER-DMF.md.
        retire_stale_generation_globals = function(self)
            Mods.retire_class("DMFMod")    -- class result -> class_registry owns the _G clear
            _G.new_mod = nil                -- DMF installation globals (not classes) -> adapter owns
            _G.get_mod = nil
        end,

        -- Diagnostic/test surface: the DMFMod table identity currently adapted
        -- (nil if none yet), and the exact Relay-installed io_dofile wrapper.
        -- Not part of the DMF-visible contract.
        adapted_dmfmod = function(self)
            return adapted_dmfmod
        end,
        adapted_io_dofile = function(self)
            return adapted_io_dofile
        end,
    }
end

return M
