-- path.lua — pure-string path utilities for the mod loader (no lfs, no
-- filesystem access).
--
-- Attribution (MIT-licensed; see THIRD_PARTY_NOTICES.md §7): `normpath` is
-- copied VERBATIM from Penlight `pl.path.normpath` 1.15.0; `is_within` is
-- adapted from `pl.path.relpath`'s segment-comparison logic minus its
-- `lfs.currentdir()` fallback (both inputs are always passed absolute).
-- Source:
-- <https://github.com/lunarmodules/Penlight/blob/e0bc8f7fce3b6a4fdef3660066f5006bf8456b32/lua/pl/path.lua>

-- Platform detection + separator via the package.config trick (what pl.path
-- delegates to via pl.compat on LuaJIT 2.1).
local is_windows = package.config:sub(1, 1) == "\\"
local sep = is_windows and "\\" or "/"

-- Locals hoisted from loop bodies (mirrors pl.path).
local sub = string.sub
local append, concat, remove = table.insert, table.concat, table.remove

-- pl.path's `at(s, i)` single-character accessor (used by normpath).
local at = function(s, i) return sub(s, i, i) end

-- pl.utils.assert_string (in spirit): type-checks and raises with Penlight's
-- argument-index/expected/got shape so normpath reads verbatim against upstream.
local function assert_string(n, val)
    if type(val) ~= "string" then
        error(("argument %d expected a 'string', got a '%s'"):format(n, type(val)), 2)
    end
    return val
end

-- pl.path's separator set (used by normpath's Windows anchor detection).
local seps = is_windows and { ["/"] = true, ["\\"] = true } or { ["/"] = true }

local M = {}

-- normalize a path name. `A//B`, `A/./B`, and `A/foo/../B` all become `A/B`;
-- an empty path results in '.'.
--
-- EXTRACTED VERBATIM from Penlight pl.path.normpath 1.15.0; the only
-- adaptations are the module-scope locals hoisted above.
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

-- Is `p` equal to or nested inside `base`? ADAPTED from Penlight pl.path.relpath's
-- segment-comparison logic minus its `lfs.currentdir()` call (both inputs are
-- always passed absolute).
--
-- Contract: BOTH inputs must be absolute + already-normalized (caller runs
-- normpath first). Segment-level comparison (so `C:\staged\mods_evil` is NOT
-- within `C:\staged\mods`); case-insensitive on Windows.
function M.is_within(p, base)
    assert_string(1, p)
    assert_string(2, base)
    local compare
    if is_windows then
        compare = function(v) return v:lower() end
    else
        compare = function(v) return v end
    end
    -- Inputs are pre-normalized (no `.`/`..`/empty segments), so gmatch over
    -- non-separator runs is exact.
    local pl, bl = {}, {}
    for seg in p:gmatch("[^" .. sep .. "]+") do pl[#pl + 1] = seg end
    for seg in base:gmatch("[^" .. sep .. "]+") do bl[#bl + 1] = seg end
    if #pl < #bl then return false end
    -- Windows drive-letter fast-out: a differing drive (e.g. C: vs D:)
    -- short-circuits before the segment walk.
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
