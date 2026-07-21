-- path.lua — pure-string path utilities for the mod loader.
--
-- Provides `normpath` (extracted verbatim from Penlight's `pl.path.normpath`)
-- and `is_within` (adapted from the segment-comparison logic in Penlight's
-- `pl.path.relpath`). Pure string manipulation: no `lfs` (LuaFileSystem), no
-- filesystem-touching operations, no module-load gymnastics.
--
-- Loaded via `Mods.load_module("path")` from `file.lua` (the first module the
-- entry bootstraps). Returns the module table.
--
-- Attribution: `normpath` is copied verbatim from Penlight `pl.path` 1.15.0
-- (MIT-licensed; see THIRD_PARTY_NOTICES.md §7). `is_within` is adapted from
-- `pl.path.relpath`'s segment-comparison logic, minus its `lfs.currentdir()`
-- fallback (we always pass both absolute paths explicitly). Source:
-- <https://github.com/lunarmodules/Penlight/blob/e0bc8f7fce3b6a4fdef3660066f5006bf8456b32/lua/pl/path.lua>

-- Platform detection + separator (mirrors pl.path's is_windows / sep setup,
-- minus pl.utils.is_windows — we use the standard package.config trick
-- directly, which is what pl.utils delegates to via pl.compat on LuaJIT 2.1).
local is_windows = package.config:sub(1, 1) == "\\"
local sep = is_windows and "\\" or "/"

-- Locals hoisted from the loop bodies (matches pl.path's style).
local sub = string.sub
local append, concat, remove = table.insert, table.concat, table.remove

-- pl.path's `at(s, i)` helper: the single-character accessor used by normpath.
local at = function(s, i) return sub(s, i, i) end

-- pl.utils.assert_string (in spirit): type-check that raises on non-string
-- input with the same argument-index + expected/got shape Penlight uses, so
-- normpath's `assert_string(1, P)` call reads verbatim against the upstream
-- source.
local function assert_string(n, val)
    if type(val) ~= "string" then
        error(("argument %d expected a 'string', got a '%s'"):format(n, type(val)), 2)
    end
    return val
end

-- pl.path's separator set (used by normpath's Windows anchor detection).
local seps = is_windows and { ["/"] = true, ["\\"] = true } or { ["/"] = true }

local M = {}

-- normalize a path name.
-- `A//B`, `A/./B`, and `A/foo/../B` all become `A/B`.
--
-- An empty path results in '.'.
--
-- EXTRACTED VERBATIM from Penlight pl.path.normpath 1.15.0. The only
-- adaptations are module-scope locals (`is_windows` for `path.is_windows`,
-- the local `sep`/`seps`/`at`/`assert_string`/`append`/`concat`/`remove`
-- hoisted above). The anchor logic (Windows UNC `\\`, drive letters `C:`,
-- POSIX `/` and `//`), the `P:gsub('/', '\\')` on Windows, the segment-stack
-- loop resolving `.` and `..`, and the empty-becomes-`.` fallback are
-- unchanged from upstream.
function M.normpath(P)
    assert_string(1, P)
    -- Split path into anchor and relative path.
    local anchor = ""
    if is_windows then
        if P:match "^\\\\" then -- UNC
            anchor = "\\\\"
            P = P:sub(3)
        elseif seps[at(P, 1)] then
            anchor = "\\"
            P = P:sub(2)
        elseif at(P, 2) == ":" then
            anchor = P:sub(1, 2)
            P = P:sub(3)
            if seps[at(P, 1)] then
                anchor = anchor .. "\\"
                P = P:sub(2)
            end
        end
        P = P:gsub("/", "\\")
    else
        -- According to POSIX, in path start '//' and '/' are distinct,
        -- but '///+' is equivalent to '/'.
        if P:match "^//" and at(P, 3) ~= "/" then
            anchor = "//"
            P = P:sub(3)
        elseif at(P, 1) == "/" then
            anchor = "/"
            P = P:match "^/*(.*)$"
        end
    end
    local parts = {}
    for part in P:gmatch("[^" .. sep .. "]+") do
        if part == ".." then
            if #parts ~= 0 and parts[#parts] ~= ".." then
                remove(parts)
            else
                append(parts, part)
            end
        elseif part ~= "." then
            append(parts, part)
        end
    end
    P = anchor .. concat(parts, sep)
    if P == "" then P = "." end
    return P
end

-- Is `p` equal to or nested inside `base`?
--
-- ADAPTED from Penlight pl.path.relpath's segment-comparison logic (the
-- `startl`/`Pl` split + per-segment `compare` walk + the Windows drive-letter
-- fast-out), minus relpath's `lfs.currentdir()` call when `start` is omitted
-- (we always receive both arguments already-absolute).
--
-- Contract: BOTH inputs must be absolute, already-normalized paths (the caller
-- normalizes via `normpath` before calling). Returns true if `p` is equal to
-- or nested inside `base`; false otherwise. Comparison is segment-level (so
-- `C:\staged\mods_evil` is NOT within `C:\staged\mods`), and on Windows it is
-- case-insensitive (drive letters and path segments alike).
function M.is_within(p, base)
    assert_string(1, p)
    assert_string(2, base)
    local compare
    if is_windows then
        compare = function(v) return v:lower() end
    else
        compare = function(v) return v end
    end
    -- Split both into segments. Inputs are pre-normalized (no `.`/`..`/empty
    -- segments), so gmatch over non-separator runs is exact.
    local pl, bl = {}, {}
    for seg in p:gmatch("[^" .. sep .. "]+") do pl[#pl + 1] = seg end
    for seg in base:gmatch("[^" .. sep .. "]+") do bl[#bl + 1] = seg end
    if #pl < #bl then return false end
    -- Windows drive-letter fast-out (adapted from relpath): a differing drive
    -- (e.g. C: vs D:) short-circuits before the segment walk.
    if is_windows and #bl > 0 and at(pl[1], 2) == ":" and compare(pl[1]) ~= compare(bl[1]) then
        return false
    end
    for i = 1, #bl do
        if compare(bl[i]) ~= compare(pl[i]) then
            return false
        end
    end
    return true
end

return M
