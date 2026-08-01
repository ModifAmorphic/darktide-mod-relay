-- file.lua — mod-root-rooted file operations for the mod loader.
--
-- All mod-relative access roots at Mods._mod_root (= _mod_path .. "/mods"); this
-- is the surface mod_manager + DMF's adapted io_* methods delegate to. Callers
-- pass a mod-RELATIVE path; resolve() rejects NUL/drive/UNC/absolute/".." as
-- path validation only (mods still hold the captured raw io), not OS-level
-- sandboxing — see the resolve() code site for the exact rules.
--
-- Rooting, raw-io redirection, and the containment threat model:
-- docs/architecture/MOD_LOADER-DMF.md (Surfaces + Raw Mods.lua.io redirection).

local _io = Mods.lua.io
-- Capture the raw io.open for internal ops. The wrapper at the bottom replaces
-- Mods.lua.io.open; _io is a table REFERENCE, so _io.open would become the
-- wrapper too. Capturing the function directly preserves the raw surface.
local _io_open = _io.open
local _loadstring = Mods.lua.loadstring
local _pcall = pcall
local _error = error
local _tostring = tostring

-- Load path utilities (normpath + is_within). Must load before the Mods.lua.io
-- wrapper below, which uses path.normpath + path.is_within.
local path = Mods.load_module("path")

Mods.file = Mods.file or {}

-- The mod root (Mods._mod_root). Captured at module load; init.lua sets it
-- before this module runs. An empty root resolves paths as-is.
local mod_root = ""
if Mods._mod_root ~= nil and Mods._mod_root ~= "" then
    -- Normalize the root itself: backslashes -> forward, strip trailing slash.
    mod_root = Mods._mod_root:gsub("\\", "/"):gsub("/+$", "")
end

-- ---------------------------------------------------------------------------
-- Internal observer mechanism (mod-loader-internal; not part of the mod-facing
-- file surface).
--
-- Observers fire AFTER a chunk executes successfully (exec/dofile variants,
-- not reads) — the trigger mod_manager uses to adapt DMF's io_* methods the
-- moment core/io.lua defines them. Observer failures are logged but never
-- replace the chunk result or crash the engine. Does NOT touch
-- Mods.require_store.
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
            Mods._relay.log_warn("file observer failed: " .. _tostring(err))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Path resolution + validation.
-- ---------------------------------------------------------------------------

-- Resolve a caller-supplied relative path to a full path rooted at mod_root.
-- Returns (full_path) | (nil, reason). If the final segment has no extension,
-- ".lua" is appended (DMF calls io_dofile/dofile with extensionless paths).
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
    -- basename contains a "." at position 2 or later (so "mods.lst" keeps .lst;
    -- a leading-dot name like ".gitignore" is treated as extension-less).
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

-- Open-once raw reader. Guarantees f:close() even if read raises. Returns
-- (true, content) | (false, err); unsafe callers convert the err to a raised
-- error.
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

-- Open-once line-list reader. Trims each line and skips blank + "--" comment
-- lines. Guarantees f:close() even if the iterator raises. Returns
-- (true, list) | (false, err).
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

-- Compile + run a chunk in the shared global env (loadstring governs the env).
-- Receives `args` as its first parameter (DMF's func(args) convention).
-- unsafe=false: returns (true, chunk_value) | (false, err).
-- unsafe=true: propagates compile/runtime errors (raises); returns chunk_value.
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
-- Safe variants return false on failure and the chunk value (with-return) or
-- true (boolean exec) on success. Unsafe variants propagate compile/runtime
-- failures. Observers fire only after a successful execution.
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
-- DMF mods load data files via the stock-DMF convention "./../mods/<mod>/<rest>"
-- passed to Mods.lua.io.open(). Without this wrapper those paths resolve
-- against the engine CWD and silently miss (DMFMod:io_* only covers mods that
-- go through mod:io_dofile(), not direct Mods.lua.io.open() callers).
--
-- The wrapper prepends _mod_root, normalizes via path.normpath (so
-- "./../mods/foo" collapses back to _mod_root/foo), and verifies the resolved
-- path stays within _mod_path (the boundary = parent of mods/). Escapes are
-- rejected with nil, err (io.open's failure shape).
--
-- The raw io captured above (_io) is preserved for internal Mods.file.* ops,
-- which already root via resolve() and must not be double-wrapped.
--
-- Containment is at the _mod_path boundary only — NOT per-mod isolation (a
-- shared Lua VM makes per-mod filesystem isolation security theater). See
-- docs/architecture/MOD_LOADER-DMF.md → "Raw io redirection" for the threat
-- model + known gaps (lexical not OS-level; symlinks/junctions;
-- FFI/os.execute bypass the wrapper).
-- ---------------------------------------------------------------------------
if Mods._mod_path and Mods._mod_path ~= "" then
    local _mod_root = Mods._mod_root
    local _normpath = path.normpath
    local _is_within = path.is_within
    -- Normalize _mod_path once at install so is_within receives the same
    -- separator form normpath produces on the joined path. Both is_within inputs
    -- must be normalized — see path.lua's is_within contract.
    local _mod_path = _normpath(Mods._mod_path)

    -- Resolve + contain a caller path. Shared by the io.open and io.lines
    -- wrappers. Rejects NUL bytes before joining, then prepends _mod_root,
    -- normalizes, and verifies containment. Returns the resolved path | (nil, reason).
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

-- ---------------------------------------------------------------------------
-- Mods.lua.io.popen wrapper — relative-path CWD redirection via cd-prepend.
--
-- Prepends `cd /d "<normpath _mod_root>" && ` so mod shell-out calls using
-- RELATIVE paths (stock-DMF `..\mods\<mod>\...`) resolve against the mods dir.
-- The cd runs in the spawned cmd.exe child only — the parent Lua CWD is never
-- touched (no SetCurrentDirectory, no FFI, no race). The opaque shell string
-- rules out the path-rewrite+containment open/lines applies.
-- See docs/architecture/MOD_LOADER-DMF.md → "Raw Mods.lua.io redirection".
-- ---------------------------------------------------------------------------
do
    local mod_root = Mods._mod_root
    if type(mod_root) == "string" and mod_root ~= ""
       and type(Mods.lua.io) == "table"
       and type(Mods.lua.io.popen) == "function" then
        -- _mod_root carries a forward slash (init.lua: _mod_path.."/mods");
        -- normpath yields the Windows form `cd /d` expects.
        local win_root = path.normpath(mod_root)
        local _orig_popen = Mods.lua.io.popen
        Mods.lua.io.popen = function(cmd, ...)
            if type(cmd) == "string" then
                return _orig_popen('cd /d "' .. win_root .. '" && ' .. cmd, ...)
            end
            return _orig_popen(cmd, ...)
        end
    end
end
