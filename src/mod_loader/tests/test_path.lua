-- test_path.lua — path utilities (src/mod_loader/path.lua).
--
-- Exercises the extracted Penlight `normpath` (anchor logic, segment-stack
-- resolution, empty-becomes-dot). All cases are string-only (no filesystem).

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
end
