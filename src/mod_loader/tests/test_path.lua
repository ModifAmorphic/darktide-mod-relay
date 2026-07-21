-- test_path.lua — path utilities (src/mod_loader/path.lua).
--
-- Exercises the extracted Penlight `normpath` (anchor logic, segment-stack
-- resolution, empty-becomes-dot) and the adapted `is_within` (segment-level
-- containment, case-insensitivity on Windows, drive-letter fast-out, the
-- sibling-prefix trap). All cases are string-only (no filesystem).

local mock = require("mock")

return function(runner)
    local function load_path()
        local sb = mock.new_sandbox()
        return mock.run_module("path", sb), sb
    end

    -- The platform separator this LuaJIT reports (mirrors path.lua's own
    -- detection). Tests assert platform-native forms: backslash on Windows,
    -- forward elsewhere.
    local is_windows = package.config:sub(1, 1) == "\\"
    local function win(win_form, posix_form)
        if is_windows then return win_form end
        return posix_form
    end

    -- ---------------------------------------------------------------------
    -- normpath
    -- ---------------------------------------------------------------------

    runner.register("path: normpath collapses A//B, A/./B, A/foo/../B to A/B", function()
        local M = load_path()
        local expected = win("A\\B", "A/B")
        runner.assert_eq(expected, M.normpath("A//B"))
        runner.assert_eq(expected, M.normpath("A/./B"))
        runner.assert_eq(expected, M.normpath("A/foo/../B"))
    end)

    runner.register("path: normpath preserves .. when it would pop below the anchor", function()
        -- ./../mods/foo: the leading ./ is nothing, the .. pops nothing (stack
        -- empty), so it is retained. Mirrors the strikamap DMF-convention case.
        local M = load_path()
        runner.assert_eq(win("..\\mods\\foo", "../mods/foo"), M.normpath("./../mods/foo"))
    end)

    runner.register("path: normpath preserves a Windows drive-letter anchor and resolves ..", function()
        local M = load_path()
        if not is_windows then
            -- On POSIX there is no drive-letter anchor; C: is just a segment.
            -- The .. still pops foo. Result: C:/bar (no anchor prefix).
            runner.assert_eq("C:/bar", M.normpath("C:/foo/../bar"))
            return
        end
        runner.assert_eq("C:\\bar", M.normpath("C:\\foo\\..\\bar"))
        runner.assert_eq("C:\\bar", M.normpath("C:/foo/../bar"),
            "forward slashes on a drive-qualified path normalize to backslashes on Windows")
    end)

    runner.register("path: normpath preserves the UNC anchor; .. pops the share (verbatim Penlight)", function()
        -- Penlight normpath: the UNC anchor \\\\ is preserved, but the stack
        -- is NOT anchored at the share — server + share are pushed as ordinary
        -- segments, so a subsequent .. pops the share. Result: \\\\server\\foo.
        -- (The stack starts empty AFTER the anchor, not after the share.)
        local M = load_path()
        if not is_windows then
            -- POSIX equivalent: a root-anchored path where .. pops a segment
            -- but cannot pop below the root anchor.
            runner.assert_eq("/server/foo", M.normpath("/server/share/../foo"))
            return
        end
        runner.assert_eq("\\\\server\\foo", M.normpath("\\\\server\\share\\..\\foo"))
    end)

    runner.register("path: normpath turns an empty path into '.'", function()
        local M = load_path()
        runner.assert_eq(".", M.normpath(""))
    end)

    runner.register("path: normpath raises on non-string input", function()
        local M = load_path()
        local ok, err = pcall(M.normpath, 123)
        runner.assert_eq(false, ok, "normpath must raise on a non-string argument")
        runner.assert_truthy(tostring(err):find("expected a 'string'") ~= nil,
            "error must identify the type mismatch")
    end)

    -- ---------------------------------------------------------------------
    -- is_within
    -- ---------------------------------------------------------------------

    runner.register("path: is_within true for a nested path", function()
        local M = load_path()
        local base = win("C:\\staged", "/staged")
        local nested = win("C:\\staged\\mods\\strikemap\\foo.lua", "/staged/mods/strikemap/foo.lua")
        runner.assert_eq(true, M.is_within(nested, base))
    end)

    runner.register("path: is_within false for a path outside the base", function()
        local M = load_path()
        local base = win("C:\\staged", "/staged")
        local outside = win("C:\\Windows\\System32\\foo", "/Windows/System32/foo")
        runner.assert_eq(false, M.is_within(outside, base))
    end)

    runner.register("path: is_within true when path equals base", function()
        local M = load_path()
        local p = win("C:\\staged", "/staged")
        runner.assert_eq(true, M.is_within(p, p))
    end)

    runner.register("path: is_within rejects the mods_evil sibling-prefix trap (segment-level)", function()
        -- String-prefix matching would wrongly accept mods_evil as inside mods.
        -- Segment-level comparison must reject it.
        local M = load_path()
        local base = win("C:\\staged\\mods", "/staged/mods")
        local sibling = win("C:\\staged\\mods_evil\\foo", "/staged/mods_evil/foo")
        runner.assert_eq(false, M.is_within(sibling, base))
    end)

    runner.register("path: is_within false when path has fewer segments than base", function()
        local M = load_path()
        local base = win("C:\\staged\\mods", "/staged/mods")
        local shallow = win("C:\\staged", "/staged")
        runner.assert_eq(false, M.is_within(shallow, base))
    end)

    runner.register("path: is_within is case-insensitive on Windows", function()
        local M = load_path()
        local base = win("C:\\staged", "/staged")
        local mixed = win("C:\\STAGED\\mods\\foo", "/STAGED/mods/foo")
        if is_windows then
            runner.assert_eq(true, M.is_within(mixed, base),
                "Windows path comparison must be case-insensitive")
        else
            -- POSIX is case-sensitive: STAGED != staged.
            runner.assert_eq(false, M.is_within(mixed, base))
        end
    end)

    runner.register("path: is_within drive-letter fast-out (C: vs D:)", function()
        local M = load_path()
        if not is_windows then
            -- No drive-letter concept on POSIX; nothing to fast-out.
            runner.assert_eq(true, true)
            return
        end
        runner.assert_eq(false, M.is_within("D:\\staged\\foo", "C:\\staged"))
    end)

    runner.register("path: is_within raises on non-string input", function()
        local M = load_path()
        local ok = pcall(M.is_within, nil, "C:\\staged")
        runner.assert_eq(false, ok, "is_within must raise when the path argument is non-string")
        local ok2 = pcall(M.is_within, "C:\\staged", nil)
        runner.assert_eq(false, ok2, "is_within must raise when the base argument is non-string")
    end)
end
