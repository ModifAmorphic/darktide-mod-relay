-- file.lua — mod-root-rooted file operations for the mod loader.
--
-- All mod-relative access roots at Mods._mod_root (derived by init.lua as
-- _mod_path .. "/mods", where _mod_path = RELAY_MOD_PATH — the mod-path
-- boundary). The operations here are the surface the loader's mod_manager +
-- DMF's adapted io_* methods delegate to.
--
-- Design is organized around explicit operations (read / execute / observe),
-- not around a generic read-or-execute dispatcher. Each operation opens the
-- file once, closes the handle before compilation/execution, and validates the
-- caller path against escape attempts.
--
-- Path safety: the caller passes a mod-RELATIVE path. We normalize backslashes
-- to forward slashes and reject NUL bytes, drive-qualified (C:\), UNC (\\server),
-- absolute (/x), and any ".." segment. This is path validation, not OS-level
-- sandboxing — mods still hold the captured raw io. Legitimate nested relative
-- paths (e.g. "dmf/scripts/mods/dmf/modules/core/io") work.

local _io = Mods.lua.io
-- Capture the raw io.open for internal Mods.file.* ops (read_raw/read_lines).
-- The wrapper at file.lua's bottom replaces Mods.lua.io.open, but _io_open
-- stays the raw function — _io is a table REFERENCE, so _io.open would become
-- the wrapper too. Capturing the function directly preserves the raw surface.
local _io_open = _io.open
local _loadstring = Mods.lua.loadstring
local _pcall = pcall
local _error = error
local _tostring = tostring
local _print = __print or print

-- Load the path utilities module (normpath + is_within). Loaded on demand via
-- Mods.load_module, which reads from MOD_LOADER_DIR. Must load before the
-- Mods.lua.io wrapper installs below, so the wrapper can use path.normpath
-- and path.is_within.
local path = Mods.load_module("path")

Mods.file = Mods.file or {}

-- The mod root (Mods._mod_root, derived as _mod_path/mods). Captured at module
-- load; init.lua sets Mods._mod_root before this module runs. An empty root
-- resolves paths as-is.
local mod_root = ""
if Mods._mod_root ~= nil and Mods._mod_root ~= "" then
    -- Normalize the root itself: backslashes -> forward, strip trailing slash.
    mod_root = Mods._mod_root:gsub("\\", "/"):gsub("/+$", "")
end

-- ---------------------------------------------------------------------------
-- Internal observer mechanism (mod-loader-internal; not part of the mod-facing file surface).
--
-- Observers fire AFTER a chunk executed successfully (exec/dofile variants,
-- not reads). They are the hook mod_manager uses to adapt DMF's io_* methods
-- the moment DMF's core/io.lua defines them (mid-DMF-init). Observer failures
-- are logged but never replace the chunk result or crash the engine. This
-- mechanism does NOT touch Mods.require_store.
-- ---------------------------------------------------------------------------
local observers = {}

function Mods.file.add_observer(fn)
    if type(fn) == "function" then
        observers[#observers + 1] = fn
    end
end

local function notify_observers(rel_path, args, result)
    for i = 1, #observers do
        local ok, err = _pcall(observers[i], rel_path, args, result)
        if not ok then
            _print("[mod_loader] file observer failed: " .. _tostring(err))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Path resolution + validation.
-- ---------------------------------------------------------------------------

-- Resolve a caller-supplied relative path to a full path rooted at mod_root.
-- Returns (full_path) on success or (nil, reason) on rejection. Normalizes
-- backslashes to forward slashes and strips trailing separators. If the final
-- path segment has no extension (no "."), ".lua" is appended — matching the
-- DMF convention where io_dofile / dofile are called with extensionless paths
-- (e.g. Mods.file.dofile("dmf/scripts/mods/dmf/dmf_loader")).
local function resolve(relative)
    if type(relative) ~= "string" then
        return nil, "non-string path"
    end
    -- Reject embedded NUL (would truncate the path at the OS boundary).
    if relative:find("\0", 1, true) then
        return nil, "nul byte in path"
    end
    local norm = relative:gsub("\\", "/")
    -- Reject drive-qualified (C:), then absolute or UNC (leading slash, which
    -- after normalization covers both "/" and "\\" -> "//").
    if norm:match("^%a:[/\\]") or norm:match("^%a:") then
        return nil, "drive-qualified path"
    end
    if norm:match("^/") then
        return nil, "absolute or UNC path"
    end
    -- Reject any ".." segment (parent traversal). gmatch over non-empty
    -- segments so leading/trailing/duplicate separators don't hide one.
    for seg in norm:gmatch("[^/]+") do
        if seg == ".." then
            return nil, "parent traversal ('..')"
        end
    end
    norm = norm:gsub("/+$", "")
    if norm == "" then
        return nil, "empty path"
    end
    -- Append .lua if the basename has no extension. "has extension" = the
    -- basename contains a "." at position 2 or later (so "mods.lst" keeps .lst,
    -- but "dmf_mod_data" gets .lua). A leading-dot name like ".gitignore" has
    -- no dot after position 1, so it is treated as extension-less and gets .lua
    -- appended — an irrelevant edge case for mod paths.
    local basename = norm:match("([^/]+)$") or norm
    local has_ext = basename:find(".", 2, true) ~= nil  -- start at 2: leading dot = ext-less
    if not has_ext then
        norm = norm .. ".lua"
    end
    if mod_root == "" then
        return norm
    end
    return mod_root .. "/" .. norm
end

-- Open-once raw reader. Guarantees f:close() even if f:read raises. Safe
-- callers receive (false, err); unsafe callers convert the err to a raised
-- error (see dofile_unsafe). Returns (true, content) or (false, err).
local function read_raw(full_path)
    local f, oerr = _io_open(full_path, "r")
    if not f then
        return false, oerr
    end
    -- pcall so a read error still reaches f:close().
    local ok, data = _pcall(function()
        return f:read("*all")
    end)
    f:close()
    if not ok then
        return false, data  -- data is the read error
    end
    if data == nil then
        return false, "read returned nil"
    end
    return true, data
end

-- Open-once line-list reader. Trims each line and skips blank lines and lines
-- whose first non-whitespace chars are "--" (single-line Lua comments).
-- Guarantees f:close() even if the lines iterator raises. Returns (true, list)
-- or (false, err).
local function read_lines(full_path)
    local f, oerr = _io_open(full_path, "r")
    if not f then
        return false, oerr
    end
    local list = {}
    -- pcall so an iterator error still reaches f:close().
    local ok, err = _pcall(function()
        for line in f:lines() do
            local trimmed = line:gsub("^%s*(.-)%s*$", "%1")
            if trimmed ~= "" and trimmed:sub(1, 2) ~= "--" then
                list[#list + 1] = trimmed
            end
        end
    end)
    f:close()
    if not ok then
        return false, err
    end
    return true, list
end

-- Compile + run a chunk. The chunk executes in the shared global environment
-- (the captured loadstring governs its env — the engine globals in production,
-- the sandbox in tests) and receives `args` as its first parameter, matching
-- the DMF chunk convention (`func(args)`).
--
-- unsafe = false: returns (true, chunk_value) on success, (false, err) on
--   compile/runtime failure.
-- unsafe = true: propagates compile/runtime errors (raises); returns the
--   chunk value on success.
local function execute(full_path, source, args, unsafe)
    local fn, lerr = _loadstring(source, full_path)
    if not fn then
        if unsafe then
            _error(lerr, 2)
        end
        return false, lerr
    end
    if unsafe then
        return fn(args)
    end
    local ok, rerr = _pcall(fn, args)
    if not ok then
        return false, rerr
    end
    return true, rerr
end

-- ---------------------------------------------------------------------------
-- Public operations.
--
-- Safe variants return false on missing/read/compile/runtime failure and the
-- chunk value (with-return) or true (boolean exec) on success. Unsafe variants
-- propagate compile/runtime failures. Observers fire only after a successful
-- execution.
-- ---------------------------------------------------------------------------

-- Safe dofile (with return). Returns the chunk value, or false on failure.
function Mods.file.dofile(path, args)
    local full, rerr = resolve(path)
    if not full then return false, rerr end
    local ok, data = read_raw(full)
    if not ok then return false, data end
    local success, value = execute(full, data, args, false)
    if not success then return false, value end
    notify_observers(path, args, value)
    return value
end

-- Unsafe dofile (with return). Propagates compile/runtime failures.
function Mods.file.dofile_unsafe(path, args)
    local full, rerr = resolve(path)
    if not full then _error(rerr, 2) end
    local ok, data = read_raw(full)
    if not ok then _error(_tostring(data), 2) end
    local value = execute(full, data, args, true)
    notify_observers(path, args, value)
    return value
end

-- Safe exec (boolean). Returns true on success, false on failure.
function Mods.file.exec(path, args)
    local full, rerr = resolve(path)
    if not full then return false end
    local ok, data = read_raw(full)
    if not ok then return false end
    local success = execute(full, data, args, false)
    if not success then return false end
    notify_observers(path, args, true)
    return true
end

-- Unsafe exec (boolean). Propagates compile/runtime failures.
function Mods.file.exec_unsafe(path, args)
    local full, rerr = resolve(path)
    if not full then _error(rerr, 2) end
    local ok, data = read_raw(full)
    if not ok then _error(_tostring(data), 2) end
    execute(full, data, args, true)
    notify_observers(path, args, true)
    return true
end

-- Safe exec with return. Same contract as dofile.
function Mods.file.exec_with_return(path, args)
    return Mods.file.dofile(path, args)
end

-- Unsafe exec with return. Same contract as dofile_unsafe.
function Mods.file.exec_unsafe_with_return(path, args)
    return Mods.file.dofile_unsafe(path, args)
end

-- Safe raw-content read. Returns the file content, or false on failure.
function Mods.file.read_content(path)
    local full, rerr = resolve(path)
    if not full then return false end
    local ok, data = read_raw(full)
    if not ok then return false end
    return data
end

-- Safe trimmed line-list read. Skips blank and "--" comment lines.
-- Returns the line list, or false on failure.
function Mods.file.read_content_to_table(path)
    local full, rerr = resolve(path)
    if not full then return false end
    local ok, list = read_lines(full)
    if not ok then return false end
    return list
end

-- ---------------------------------------------------------------------------
-- Mods.lua.io.open / io.lines wrapper.
--
-- DMF mods load their own data files via the stock-DMF convention
-- "./../mods/<modname>/<rest>", passed to Mods.lua.io.open(). Without this
-- wrapper, those paths resolve against the engine CWD (the game's binaries/
-- dir) and silently miss — the DMFMod:io_* adaptation only covers mods that
-- go through mod:io_dofile(), not mods that call Mods.lua.io.open() directly.
--
-- The wrapper prepends _mod_root (the mods dir), normalizes via path.normpath
-- (so "./../mods/foo" collapses back to _mod_root/foo), and verifies the
-- resolved path stays within _mod_path (the boundary = parent of mods/).
-- Escapes are rejected with nil, err (mirroring io.open's failure shape).
--
-- The raw io captured above as _io is preserved for the internal Mods.file.*
-- operations, which already root paths via resolve() and must not be
-- double-wrapped.
--
-- Containment is at the _mod_path boundary only — NOT per-mod isolation. Mods
-- can traverse to sibling mods' files within <mod_path>/mods/. This is
-- intentional (a shared Lua VM means per-mod filesystem isolation would be
-- security theater). See docs/architecture/MOD_LOADER-DMF.md → "Raw io
-- redirection" for the threat model + known gaps (lexical containment, not
-- OS-level sandboxing; symlinks/junctions; FFI/os.execute bypass the wrapper).
-- ---------------------------------------------------------------------------
if Mods._mod_path and Mods._mod_path ~= "" then
    local _mod_root = Mods._mod_root
    local _normpath = path.normpath
    local _is_within = path.is_within
    -- Normalize _mod_path once at install time so is_within receives the same
    -- separator form normpath produces on the joined path (backslashes on
    -- Windows). The caller (this closure) is responsible for normalizing both
    -- is_within inputs — see path.lua's is_within contract.
    local _mod_path = _normpath(Mods._mod_path)

    -- Resolve + contain a caller-supplied path. Shared by the io.open and
    -- io.lines wrappers. Rejects NUL bytes (would truncate at the OS boundary,
    -- matching resolve()) before joining; then prepends _mod_root, normalizes,
    -- and verifies containment. Returns the resolved absolute path, or
    -- (nil, reason) on rejection.
    local function resolve_and_check(file_path)
        if type(file_path) == "string" and file_path:find("\0", 1, true) then
            return nil, "nul byte in path"
        end
        local joined = _mod_root .. "/" .. tostring(file_path)
        local resolved = _normpath(joined)
        if not _is_within(resolved, _mod_path) then
            return nil, "path escapes mod path boundary"
        end
        return resolved
    end

    local _original_io_open = Mods.lua.io.open
    Mods.lua.io.open = function(file_path, mode)
        local resolved, err = resolve_and_check(file_path)
        if not resolved then return nil, err end
        return _original_io_open(resolved, mode)
    end

    local _original_io_lines = Mods.lua.io.lines
    Mods.lua.io.lines = function(file_path, ...)
        local resolved, err = resolve_and_check(file_path)
        if not resolved then return nil, err end
        return _original_io_lines(resolved, ...)
    end
end
