-- file.lua — mod-root-rooted file operations for the mod loader.
--
-- All mod-relative access roots at Mods._mod_root (= _mod_path .. "/mods"); this
-- is the surface mod_manager + DMF's adapted io_* methods delegate to. Callers
-- pass a mod-RELATIVE path (or join-form components — see normalize_args);
-- resolve() rejects NUL/drive/UNC/absolute/".." for
-- the internal code-loading surface (Mods.file.*) only — path validation, not
-- OS-level sandboxing (mods still hold the captured raw io). See the resolve()
-- code site for the exact rules.
--
-- Rooting + raw-io redirection (the mod-facing Mods.lua.io wrapper roots
-- relative paths and passes absolute paths through verbatim):
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

-- Load path utilities. Must load before the Mods.lua.io wrapper below, which
-- uses path.normpath.
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

-- Validate one join-form component as a single path segment: a non-empty
-- string with no "..", separator, NUL, or ":" (a colon spliced mid-path
-- could qualify a drive or an NTFS alternate data stream — resolve() only
-- rejects those at the path start). Returns (component) | (nil, reason).
local function check_component(value)
    if type(value) ~= "string" then
        return nil, "non-string path component"
    end
    if value == "" then
        return nil, "empty path component"
    end
    if value == ".." then
        return nil, "'..' path component"
    end
    if value:find("\0", 1, true) then
        return nil, "nul byte in path component"
    end
    if value:find("/", 1, true) or value:find("\\", 1, true) then
        return nil, "path separator in path component"
    end
    if value:find(":", 1, true) then
        return nil, "':' in path component"
    end
    return value
end

-- Normalize a public op's arguments to (relative_path, args), or
-- (nil, nil, reason) on a join-form component violation. A STRING second
-- argument selects the join form — (name, ext) -> "<name>.<ext>" or
-- (dir, name, ext[, args]) -> "<dir>/<name>.<ext>", ext BARE ("mod", not
-- ".mod"; components validated per check_component) — so the joined basename
-- always carries an extension (resolve()'s .lua append never fires on it).
-- Any other second argument is the path form, returned verbatim. Full
-- surface contract: docs/reference/relay/manager-slot.md.
local function normalize_args(first, second, third, fourth)
    if type(second) ~= "string" then
        return first, second
    end
    if third == nil then
        local name, nerr = check_component(first)
        if not name then return nil, nil, nerr end
        local ext, eerr = check_component(second)
        if not ext then return nil, nil, eerr end
        return name .. "." .. ext, fourth
    end
    local dir, derr = check_component(first)
    if not dir then return nil, nil, derr end
    local name, nerr = check_component(second)
    if not name then return nil, nil, nerr end
    local ext, eerr = check_component(third)
    if not ext then return nil, nil, eerr end
    return dir .. "/" .. name .. "." .. ext, fourth
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
--
-- Every op takes two argument shapes, selected by the second argument (the
-- discriminator + component rules live in normalize_args): the path form
-- (path, args?) — args any non-string type, ignored by reads — or the join
-- form (name, ext) / (dir, name, ext[, args]) — the manager-slot convention
-- (AML: exec_with_return(folder, folder, "mod")). Full surface contract:
-- docs/reference/relay/manager-slot.md.
-- ---------------------------------------------------------------------------

-- Safe dofile (with return). Returns the chunk value, or false on failure.
function Mods.file.dofile(...)
    local rel, args, err = normalize_args(...)
    if err ~= nil then return false, err end
    local full, rerr = resolve(rel)
    if not full then return false, rerr end
    local ok, data = read_raw(full)
    if not ok then return false, data end
    local success, value = execute(full, data, args, false)
    if not success then return false, value end
    notify_observers(rel, args, value)
    return value
end

-- Unsafe dofile (with return). Propagates compile/runtime failures.
function Mods.file.dofile_unsafe(...)
    local rel, args, err = normalize_args(...)
    if err ~= nil then _error(err, 2) end
    local full, rerr = resolve(rel)
    if not full then _error(rerr, 2) end
    local ok, data = read_raw(full)
    if not ok then _error(_tostring(data), 2) end
    local value = execute(full, data, args, true)
    notify_observers(rel, args, value)
    return value
end

-- Safe exec (boolean). Returns true on success, false on failure.
function Mods.file.exec(...)
    local rel, args, err = normalize_args(...)
    if err ~= nil then return false end
    local full, rerr = resolve(rel)
    if not full then return false end
    local ok, data = read_raw(full)
    if not ok then return false end
    local success = execute(full, data, args, false)
    if not success then return false end
    notify_observers(rel, args, true)
    return true
end

-- Unsafe exec (boolean). Propagates compile/runtime failures.
function Mods.file.exec_unsafe(...)
    local rel, args, err = normalize_args(...)
    if err ~= nil then _error(err, 2) end
    local full, rerr = resolve(rel)
    if not full then _error(rerr, 2) end
    local ok, data = read_raw(full)
    if not ok then _error(_tostring(data), 2) end
    execute(full, data, args, true)
    notify_observers(rel, args, true)
    return true
end

-- Safe exec with return. Same contract as dofile.
function Mods.file.exec_with_return(...)
    return Mods.file.dofile(...)
end

-- Unsafe exec with return. Same contract as dofile_unsafe.
function Mods.file.exec_unsafe_with_return(...)
    return Mods.file.dofile_unsafe(...)
end

-- Safe raw-content read. Returns the file content, or false on failure.
function Mods.file.read_content(...)
    local rel, _, err = normalize_args(...)
    if err ~= nil then return false end
    local full, rerr = resolve(rel)
    if not full then return false end
    local ok, data = read_raw(full)
    if not ok then return false end
    return data
end

-- Safe trimmed line-list read. Skips blank and "--" comment lines.
-- Returns the line list, or false on failure.
function Mods.file.read_content_to_table(...)
    local rel, _, err = normalize_args(...)
    if err ~= nil then return false end
    local full, rerr = resolve(rel)
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
-- against the engine CWD (binaries/) and silently miss (DMFMod:io_* only covers
-- mods that go through mod:io_dofile(), not direct Mods.lua.io.open() callers).
--
-- The wrapper does ONE thing — make that relative convention resolve:
--   - relative path -> path.normpath(_mod_root .. "/" .. file_path)
--   - absolute path -> forwarded VERBATIM (no rooting, no normalization, the
--     caller's separators preserved) — so mods can read/write anywhere, like
--     stock DMF (e.g. the Scores mod's %APPDATA% history writes)
--   - non-string    -> forwarded as-is (the original io handles/raises)
--
-- The wrapper is a routing shim, not a sandbox: a mod runs Lua in-process and
-- can read or write any path via os.execute/FFI/absolute io.popen (and now
-- io.open/io.lines). It exists solely because the engine CWD is binaries/, not
-- mods/ — without rooting, DMF's ./../mods/<rest> convention resolves to the
-- wrong directory.
--
-- The raw io captured above (_io) is preserved for internal Mods.file.* ops,
-- which already root via resolve() and must not be double-wrapped.
--
-- Skipped when mods are hosted in the game tree (the launcher-derived
-- Mods._relay.mods_in_game_tree gate, snapshotted by init.lua before this
-- module loads): the mod path IS the game directory, so the stock DMF
-- convention already resolves naturally from binaries/ — no wrapper installs.
-- Nil-safe (no Mods._relay = not gated).
--
-- See docs/architecture/MOD_LOADER-DMF.md → "Raw Mods.lua.io redirection" for
-- the raw-io semantics.
-- ---------------------------------------------------------------------------
if Mods._mod_root and Mods._mod_root ~= ""
   and not (Mods._relay and Mods._relay.mods_in_game_tree == true) then
    local _mod_root = Mods._mod_root
    local _normpath = path.normpath

    -- Resolve a caller path for the mod-facing io surface: root a relative
    -- path at _mod_root (normalized), or forward an absolute path verbatim.
    -- Non-string paths pass through so the original io handles/raises. Absolute
    -- iff, after "\"->"/", the form is drive-qualified (^%a: — covers C:/x,
    -- C:\x, C:x) or root-anchored (^/ — also covers UNC, \\server -> //server).
    -- These mirror the patterns resolve() rejects; here they select passthrough.
    local function resolve(file_path)
        if type(file_path) ~= "string" then
            return file_path
        end
        local fwd = file_path:gsub("\\", "/")
        if fwd:match("^%a:") or fwd:match("^/") then
            return file_path
        end
        return _normpath(_mod_root .. "/" .. file_path)
    end

    local _original_io_open = Mods.lua.io.open
    Mods.lua.io.open = function(file_path, mode)
        return _original_io_open(resolve(file_path), mode)
    end

    local _original_io_lines = Mods.lua.io.lines
    Mods.lua.io.lines = function(file_path, ...)
        return _original_io_lines(resolve(file_path), ...)
    end
end

-- ---------------------------------------------------------------------------
-- Mods.lua.io.popen wrapper — relative-path CWD redirection via cd-prepend.
--
-- Prepends `cd /d "<normpath _mod_root>" && ` so mod shell-out calls using
-- RELATIVE paths (stock-DMF `..\mods\<mod>\...`) resolve against the mods dir.
-- The cd runs in the spawned cmd.exe child only — the parent Lua CWD is never
-- touched (no SetCurrentDirectory, no FFI, no race). The opaque shell string
-- rules out the path-rewrite that open/lines applies.
-- Skipped when mods are hosted in the game tree (the same
-- Mods._relay.mods_in_game_tree gate as the open/lines wrapper — stock
-- conventions resolve naturally from binaries/). Nil-safe.
-- See docs/architecture/MOD_LOADER-DMF.md → "Raw Mods.lua.io redirection".
-- ---------------------------------------------------------------------------
do
    local mod_root = Mods._mod_root
    if type(mod_root) == "string" and mod_root ~= ""
       and not (Mods._relay and Mods._relay.mods_in_game_tree == true)
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
