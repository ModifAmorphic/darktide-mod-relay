-- test_file.lua — Mods.file.* behavior (src/mod_loader/file.lua).
--
-- Asserts the external behavior of the mod-root-rooted file operations:
--   - path validation: rejects absolute/UNC/drive/NUL/..; allows nested relative
--   - safe/unsafe distinction: safe returns false on failure, unsafe raises
--   - single-open: the handle is closed before compile/run and on read failure
--   - reads: raw content + trimmed line list (blank/comment skipped)
--   - observer isolation: observers fire only after successful exec, failures
--     are logged without replacing the chunk result

local mock = require("mock")

return function(runner)
    -- Build a sandbox with Mods.lua.{io,loadstring} and Mods._mod_root wired,
    -- then load file.lua into it. Returns the sandbox + the io mock (for
    -- open-count assertions).
    local function setup(files, mod_root)
        local sb = mock.new_sandbox()
        sb.Mods = { lua = {}, _mod_root = mod_root or mock.MOD_ROOT }
        local iot = mock.make_io(files or {})
        sb.Mods.lua.io = iot
        sb.Mods.lua.loadstring = sb.loadstring
        sb.__print = function() end
        mock.attach_logger(sb)
        -- file.lua loads path.lua via Mods.load_module at its top; wire it to
        -- the mock loader so the existing setup() keeps working. The wrapper
        -- installs here too (it keys off _mod_root, which setup() sets), but
        -- Mods.file.* closes over the raw _io_open captured before the wrapper
        -- installs, so this sandbox tests the raw Mods.file.* behavior only.
        sb.Mods.load_module = function(name)
            return mock.run_module(name, sb)
        end
        mock.run_module("file", sb)
        return sb, iot
    end

    -- Build a sandbox with the Mods.lua.io wrapper installed. Provides both
    -- _mod_path (the mod-path config) and _mod_root (the mods dir) on Mods,
    -- then loads file.lua — which loads path.lua + installs the io.open/
    -- io.lines wrappers (keyed on _mod_root). Returns the sandbox + the io mock.
    local function setup_with_wrapper(files, mod_path)
        local sb = mock.new_sandbox()
        mod_path = mod_path or "C:/staged"
        sb.Mods = {
            lua = {},
            _mod_path = mod_path,
            _mod_root = mod_path .. "/mods",
        }
        local iot = mock.make_io(files or {})
        sb.Mods.lua.io = iot
        sb.Mods.lua.loadstring = sb.loadstring
        sb.__print = function() end
        mock.attach_logger(sb)
        sb.Mods.load_module = function(name)
            return mock.run_module(name, sb)
        end
        mock.run_module("file", sb)
        return sb, iot
    end

    -- ---------------------------------------------------------------------
    -- Path validation
    -- ---------------------------------------------------------------------

    runner.register("file: dofile resolves a nested relative path under the mod root", function()
        local files = { [mock.MOD_ROOT .. "/dmf/scripts/mods/x.lua"] = "return 42" }
        local sb = setup(files)
        local v = sb.Mods.file.dofile("dmf/scripts/mods/x")
        runner.assert_eq(42, v, "dofile should return the chunk value for a valid relative path")
    end)

    runner.register("file: backslash paths are normalized and resolve", function()
        local files = { [mock.MOD_ROOT .. "/sub/inner.lua"] = "return 'ok'" }
        local sb = setup(files)
        local v = sb.Mods.file.dofile("sub\\inner")
        runner.assert_eq("ok", v, "backslash separators should normalize to forward slashes")
    end)

    runner.register("file: dofile with .lua extension already present resolves", function()
        local files = { [mock.MOD_ROOT .. "/a/b.lua"] = "return 1" }
        local sb = setup(files)
        runner.assert_eq(1, sb.Mods.file.dofile("a/b.lua"))
    end)

    runner.register("file: rejects absolute path (returns false, safe)", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.dofile("/etc/passwd"),
            "absolute path must be rejected")
    end)

    runner.register("file: rejects UNC path", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.dofile("//server/share/x"))
    end)

    runner.register("file: rejects backslash UNC path", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.dofile("\\\\server\\share\\x"))
    end)

    runner.register("file: rejects drive-qualified path", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.dofile("C:/secrets"))
        runner.assert_eq(false, sb.Mods.file.dofile("D:\\secrets"))
    end)

    runner.register("file: rejects parent traversal (..) in any segment", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.dofile("../escape"))
        runner.assert_eq(false, sb.Mods.file.dofile("foo/../bar"))
        runner.assert_eq(false, sb.Mods.file.dofile("a/b/../../c"))
        runner.assert_eq(false, sb.Mods.file.dofile("x/.."))
    end)

    runner.register("file: rejects NUL byte in path", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.dofile("safe\0evil"))
    end)

    runner.register("file: a path containing '..' as a substring but not a segment is allowed", function()
        -- "..bar" is a filename, not a parent traversal. Validation must accept
        -- it (it is not rejected as ".." traversal). Pass the full filename so
        -- extension handling is unambiguous.
        local files = { [mock.MOD_ROOT .. "/foo/..bar.lua"] = "return 'fine'" }
        local sb = setup(files)
        runner.assert_eq("fine", sb.Mods.file.dofile("foo/..bar.lua"))
    end)

    -- ---------------------------------------------------------------------
    -- Safe vs unsafe distinction
    -- ---------------------------------------------------------------------

    runner.register("file: safe dofile returns false on missing file", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.dofile("nope/missing"))
    end)

    runner.register("file: safe dofile returns false on compile error", function()
        local files = { [mock.MOD_ROOT .. "/broken.lua"] = "this is not lua" }
        local sb = setup(files)
        runner.assert_eq(false, sb.Mods.file.dofile("broken"))
    end)

    runner.register("file: safe dofile returns false on runtime error", function()
        local files = { [mock.MOD_ROOT .. "/boom.lua"] = "error('boom')" }
        local sb = setup(files)
        runner.assert_eq(false, sb.Mods.file.dofile("boom"))
    end)

    runner.register("file: unsafe dofile propagates a compile error", function()
        local files = { [mock.MOD_ROOT .. "/broken.lua"] = "this is not lua" }
        local sb = setup(files)
        local ok, err = pcall(sb.Mods.file.dofile_unsafe, "broken")
        runner.assert_eq(false, ok, "unsafe dofile must raise on compile error")
        runner.assert_truthy(err ~= nil, "must carry the error")
    end)

    runner.register("file: unsafe dofile propagates a runtime error", function()
        local files = { [mock.MOD_ROOT .. "/boom.lua"] = "error('kaboom')" }
        local sb = setup(files)
        local ok, err = pcall(sb.Mods.file.dofile_unsafe, "boom")
        runner.assert_eq(false, ok)
        runner.assert_truthy(tostring(err):find("kaboom") ~= nil, "runtime error must propagate")
    end)

    runner.register("file: exec returns boolean true on success, false on failure", function()
        local files = { [mock.MOD_ROOT .. "/ok.lua"] = "return 'ignored'" }
        local sb = setup(files)
        runner.assert_eq(true, sb.Mods.file.exec("ok"))
        runner.assert_eq(false, sb.Mods.file.exec("missing"))
    end)

    runner.register("file: exec_unsafe raises on runtime failure", function()
        local files = { [mock.MOD_ROOT .. "/boom.lua"] = "error('x')" }
        local sb = setup(files)
        local ok = pcall(sb.Mods.file.exec_unsafe, "boom")
        runner.assert_eq(false, ok)
    end)

    runner.register("file: exec_with_return / exec_unsafe_with_return match dofile contracts", function()
        local files = { [mock.MOD_ROOT .. "/v.lua"] = "return 'val'" }
        local sb = setup(files)
        runner.assert_eq("val", sb.Mods.file.exec_with_return("v"))
        runner.assert_eq("val", sb.Mods.file.exec_unsafe_with_return("v"))
        runner.assert_eq(false, sb.Mods.file.exec_with_return("missing"))
    end)

    runner.register("file: dofile forwards args to the chunk", function()
        local files = { [mock.MOD_ROOT .. "/arg.lua"] = "local a = ... return a" }
        local sb = setup(files)
        runner.assert_eq("hello", sb.Mods.file.dofile("arg", "hello"))
    end)

    -- ---------------------------------------------------------------------
    -- Reads
    -- ---------------------------------------------------------------------

    runner.register("file: read_content returns the raw file content", function()
        local files = { [mock.MOD_ROOT .. "/raw.lua"] = "line1\nline2\n" }
        local sb = setup(files)
        runner.assert_eq("line1\nline2\n", sb.Mods.file.read_content("raw.lua"))
    end)

    runner.register("file: read_content returns false on missing file", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.read_content("missing"))
    end)

    runner.register("file: read_content_to_table trims + skips blank and -- comment lines", function()
        local files = {
            [mock.MOD_ROOT .. "/list.lst"] = table.concat({
                "alpha",
                "  bravo  ",
                "",
                "-- a comment",
                "   -- indented comment",
                "charlie",
            }, "\n"),
        }
        local sb = setup(files)
        runner.assert_eq({ "alpha", "bravo", "charlie" }, sb.Mods.file.read_content_to_table("list.lst"))
    end)

    runner.register("file: read_content_to_table returns false on missing file", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.read_content_to_table("missing"))
    end)

    -- ---------------------------------------------------------------------
    -- Single-open behavior
    -- ---------------------------------------------------------------------

    runner.register("file: dofile opens the file exactly once per operation", function()
        -- The mock io counts opens; a single dofile must open exactly once
        -- (read), close, then compile+run (no second open).
        local opens = 0
        local files = { [mock.MOD_ROOT .. "/once.lua"] = "return 1" }
        local sb = mock.new_sandbox()
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }
        local base_io = mock.make_io(files)
        sb.Mods.lua.io = { open = function(p, m) opens = opens + 1; return base_io.open(p, m) end }
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function() end
        mock.run_module("file", sb)
        runner.assert_eq(1, sb.Mods.file.dofile("once"))
        runner.assert_eq(1, opens, "dofile must open the file exactly once")
    end)

    -- ---------------------------------------------------------------------
    -- Handle cleanup on read/iterator errors
    -- ---------------------------------------------------------------------

    runner.register("file: read_raw closes the handle even when f:read raises (safe returns false)", function()
        -- A mock handle whose :read("*all") raises. The safe dofile must
        -- receive false (not the escaping error) and the handle must be closed
        -- exactly once.
        local closes = 0
        local files = { [mock.MOD_ROOT .. "/boom.lua"] = "irrelevant" }
        local sb = mock.new_sandbox()
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }
        local base_io = mock.make_io(files)
        sb.Mods.lua.io = {
            open = function(path, mode)
                local f = base_io.open(path, mode)
                if f then
                    -- Replace read with one that raises; track close.
                    f.read = function() error("induced read failure") end
                    local orig_close = f.close
                    f.close = function() closes = closes + 1; return orig_close() end
                end
                return f
            end,
        }
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function() end
        mock.run_module("file", sb)
        local v = sb.Mods.file.dofile("boom")
        runner.assert_eq(false, v, "safe dofile must return false on a read error, not propagate")
        runner.assert_eq(1, closes, "handle must be closed exactly once even when read raises")
    end)

    runner.register("file: read_lines closes the handle even when the iterator raises (safe returns false)", function()
        -- A mock handle whose :lines() iterator raises mid-iteration. The safe
        -- read_content_to_table must return false and the handle must close once.
        local closes = 0
        local files = { [mock.MOD_ROOT .. "/list.lst"] = "alpha\nbeta\n" }
        local sb = mock.new_sandbox()
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }
        local base_io = mock.make_io(files)
        sb.Mods.lua.io = {
            open = function(path, mode)
                local f = base_io.open(path, mode)
                if f then
                    f.lines = function()
                        error("induced iterator failure")
                    end
                    local orig_close = f.close
                    f.close = function() closes = closes + 1; return orig_close() end
                end
                return f
            end,
        }
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function() end
        mock.run_module("file", sb)
        local v = sb.Mods.file.read_content_to_table("list.lst")
        runner.assert_eq(false, v, "safe read_content_to_table must return false on an iterator error")
        runner.assert_eq(1, closes, "handle must be closed exactly once even when the iterator raises")
    end)

    runner.register("file: unsafe dofile converts a read error to a raised error (handle still closes)", function()
        -- Unsafe execution propagates failures; a read failure surfaces as a
        -- raised error. The handle must still close exactly once.
        local closes = 0
        local files = { [mock.MOD_ROOT .. "/boom.lua"] = "irrelevant" }
        local sb = mock.new_sandbox()
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }
        local base_io = mock.make_io(files)
        sb.Mods.lua.io = {
            open = function(path, mode)
                local f = base_io.open(path, mode)
                if f then
                    f.read = function() error("induced read failure") end
                    local orig_close = f.close
                    f.close = function() closes = closes + 1; return orig_close() end
                end
                return f
            end,
        }
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function() end
        mock.run_module("file", sb)
        local ok, err = pcall(sb.Mods.file.dofile_unsafe, "boom")
        runner.assert_eq(false, ok, "unsafe dofile must raise on a read failure")
        runner.assert_truthy(tostring(err):find("induced read failure") ~= nil,
            "the read error must surface")
        runner.assert_eq(1, closes, "handle must close exactly once even for the unsafe path")
    end)

    -- ---------------------------------------------------------------------
    -- Observer isolation
    -- ---------------------------------------------------------------------

    runner.register("file: observers fire after successful exec with the path + result", function()
        local files = { [mock.MOD_ROOT .. "/seen.lua"] = "return 'chunk-result'" }
        local sb = setup(files)
        local seen = nil
        sb.Mods.file.add_observer(function(path, args, result)
            seen = { path = path, result = result }
        end)
        local v = sb.Mods.file.dofile("seen")
        runner.assert_eq("chunk-result", v)
        runner.assert_eq("seen", seen.path, "observer must receive the relative path")
        runner.assert_eq("chunk-result", seen.result, "observer must receive the chunk result")
    end)

    runner.register("file: observers do NOT fire on failed exec", function()
        local files = { [mock.MOD_ROOT .. "/boom.lua"] = "error('x')" }
        local sb = setup(files)
        local fired = false
        sb.Mods.file.add_observer(function() fired = true end)
        sb.Mods.file.dofile("boom")  -- fails
        runner.assert_eq(false, fired, "observer must not fire on runtime failure")
    end)

    runner.register("file: observers do NOT fire on reads", function()
        local files = { [mock.MOD_ROOT .. "/data.txt"] = "hello" }
        local sb = setup(files)
        local fired = false
        sb.Mods.file.add_observer(function() fired = true end)
        sb.Mods.file.read_content("data.txt")
        sb.Mods.file.read_content_to_table("data.txt")
        runner.assert_eq(false, fired, "observers must not fire for read operations")
    end)

    runner.register("file: observer failure is logged but does not replace the chunk result", function()
        local files = { [mock.MOD_ROOT .. "/ok.lua"] = "return 'real'" }
        local logged = {}
        local sb = mock.new_sandbox()
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }
        sb.Mods.lua.io = mock.make_io(files)
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function(msg) table.insert(logged, msg) end
        mock.attach_logger(sb)
        mock.run_module("file", sb)
        sb.Mods.file.add_observer(function() error("observer boom") end)
        local v = sb.Mods.file.dofile("ok")
        runner.assert_eq("real", v, "chunk result must be returned despite observer failure")
        runner.assert_truthy(#logged >= 1, "observer failure must be logged")
        runner.assert_truthy(logged[1]:find("observer failed") ~= nil,
            "log must identify the observer failure")
    end)

    -- ---------------------------------------------------------------------
    -- Mods.lua.io.open / io.lines wrapper (the raw-io redirection)
    -- ---------------------------------------------------------------------
    --
    -- The wrapper roots relative paths at _mod_root (normalized) and forwards
    -- absolute paths verbatim (no containment). These tests use the
    -- setup_with_wrapper() helper which provides both _mod_path and _mod_root
    -- and lets file.lua install the wrapper (keyed on _mod_root).

    runner.register("io wrapper: resolves the DMF ./../mods/<mod>/<rest> convention", function()
        -- The strikamap-style data load: a mod opens "./../mods/strikemap/maps/foo.lua".
        -- The wrapper prepends _mod_root (C:/staged/mods), normalizes via
        -- normpath (collapsing the ./../mods back to
        -- _mod_root/strikemap/maps/foo.lua), and forwards to the underlying
        -- io.open. The mock io stages the file at the forward-slash form; the
        -- mock's normkey handles the platform-native separator the wrapper
        -- produces.
        local files = { ["C:/staged/mods/strikemap/maps/foo.lua"] = "map geometry" }
        local sb, iot = setup_with_wrapper(files)
        local f, err = sb.Mods.lua.io.open("./../mods/strikemap/maps/foo.lua")
        runner.assert_not_nil(f, "open should succeed for an in-bounds DMF-convention path; got err: " .. tostring(err))
        runner.assert_eq("map geometry", f:read("*all"))
        f:close()
    end)

    runner.register("io wrapper: write mode resolves through the same path", function()
        local files = { ["C:/staged/mods/strikemap/diag.txt"] = "diag-data" }
        local sb = setup_with_wrapper(files)
        local f, err = sb.Mods.lua.io.open("./../mods/strikemap/diag.txt", "w")
        runner.assert_not_nil(f, "write-mode open should resolve the same way; got err: " .. tostring(err))
        f:close()
    end)

    runner.register("io wrapper: roots + forwards relative traversal paths without containment", function()
        -- Containment was removed: a relative traversal path is rooted at
        -- _mod_root, normpath'd, and FORWARDED to the underlying io.open —
        -- NOT rejected. From _mod_root C:/staged/mods, the traversal
        -- "../../Windows/System32/config/SAM" normpaths to the Windows dir.
        -- Compute the expected path via path.normpath so the assertion is
        -- platform-correct (backslashes on Windows, forward on Linux — matching
        -- what the wrapper produces). The underlying io.open receives the rooted
        -- path and misses there (normal io.open failure shape); no nil,err
        -- rejection occurs.
        local path_mod = mock.run_module("path", mock.new_sandbox())
        local mod_root = "C:/staged/mods"
        local rel = "../../Windows/System32/config/SAM"
        local expected = path_mod.normpath(mod_root .. "/" .. rel)
        local opened_with = nil
        local sb = mock.new_sandbox()
        sb.Mods = {
            lua = {},
            _mod_path = "C:/staged",
            _mod_root = mod_root,
        }
        local base_io = mock.make_io({})
        sb.Mods.lua.io = {
            open = function(p, m) opened_with = p; return base_io.open(p, m) end,
            lines = base_io.lines,
        }
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function() end
        mock.run_module("file", sb)
        local f, err = sb.Mods.lua.io.open(rel)
        runner.assert_eq(expected, opened_with,
            "underlying io.open must receive the normpath-resolved rooted path (no containment rejection)")
        runner.assert_nil(f, "the file is not staged, so the underlying io.open returns nil (normal miss)")
        runner.assert_truthy(err ~= nil, "the miss carries io.open's own err string (the wrapper did not reject)")
    end)

    runner.register("io wrapper: sibling-prefix path resolves + forwards (rooting only, no boundary)", function()
        -- ./../mods_evil/foo from _mod_root (C:/staged/mods) normpaths to
        -- C:/staged/mods_evil/foo. There is no containment now, so the wrapper
        -- simply roots + forwards the path; whether the open then succeeds
        -- depends on whether the file is staged (normal io.open failure shape
        -- on a miss). This test stages the file and verifies the open reaches it.
        local files = { ["C:/staged/mods_evil/foo.lua"] = "sibling content" }
        local sb = setup_with_wrapper(files)
        local f, err = sb.Mods.lua.io.open("./../mods_evil/foo.lua")
        runner.assert_not_nil(f,
            "sibling-prefix path must resolve + forward (rooting only); got err: " .. tostring(err))
        runner.assert_eq("sibling content", f:read("*all"))
        f:close()
    end)

    runner.register("io wrapper: io.lines resolves through the same path as io.open", function()
        local files = { ["C:/staged/mods/strikemap/data.lst"] = "alpha\nbeta\n" }
        local sb = setup_with_wrapper(files)
        local lines = sb.Mods.lua.io.lines("./../mods/strikemap/data.lst")
        runner.assert_type("function", lines, "io.lines must return an iterator")
        local collected = {}
        for line in lines do collected[#collected + 1] = line end
        runner.assert_eq({ "alpha", "beta" }, collected)
    end)

    runner.register("io wrapper: io.lines forwards rooted traversal paths without containment", function()
        -- Mirror of the io.open traversal test: io.lines forwards the rooted/
        -- normpath'd traversal path to the underlying io.lines — NOT rejected.
        -- io.lines returns an iterator (not nil,err), so the recording mock
        -- captures what the underlying io.lines RECEIVED. The underlying mock
        -- io.lines raises on a not-found path; since the wrapper forwarded
        -- (did not reject), that raise propagates from the underlying io.lines.
        local path_mod = mock.run_module("path", mock.new_sandbox())
        local mod_root = "C:/staged/mods"
        local rel = "../../somewhere/data.lst"
        local expected = path_mod.normpath(mod_root .. "/" .. rel)
        local lines_with = nil
        local sb = mock.new_sandbox()
        sb.Mods = {
            lua = {},
            _mod_path = "C:/staged",
            _mod_root = mod_root,
        }
        local base_io = mock.make_io({})
        sb.Mods.lua.io = {
            open = base_io.open,
            lines = function(p, ...) lines_with = p; return base_io.lines(p, ...) end,
        }
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function() end
        mock.run_module("file", sb)
        local ok = pcall(sb.Mods.lua.io.lines, rel)
        runner.assert_eq(false, ok,
            "underlying io.lines raises on the unstaged forwarded path (no wrapper rejection)")
        runner.assert_eq(expected, lines_with,
            "underlying io.lines must receive the normpath-resolved rooted path")
    end)

    runner.register("io wrapper: absolute paths pass through verbatim (raw-io semantics)", function()
        -- The Scores-mod class regression guard: mods persist to absolute paths
        -- outside <mod_path> (e.g. %APPDATA%\...\scores_history\v1\<ts>.lua).
        -- The wrapper must forward an absolute path VERBATIM — no _mod_root
        -- prefix, no normalization, no separator rewrite. Stage nothing; use a
        -- recording open to capture exactly what the underlying io.open got.
        -- Both a forward-slash absolute path and a backslash absolute path are
        -- covered (backslashes preserved on the latter).
        local opened = {}
        local sb = mock.new_sandbox()
        sb.Mods = {
            lua = {},
            _mod_path = "C:/staged",
            _mod_root = "C:/staged/mods",
        }
        local base_io = mock.make_io({})
        sb.Mods.lua.io = {
            open = function(p, m) opened[#opened + 1] = { p = p, m = m }; return base_io.open(p, m) end,
            lines = base_io.lines,
        }
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function() end
        mock.run_module("file", sb)
        -- Forward-slash absolute path (the Scores APPDATA write):
        local fwd = "C:/Users/example/AppData/Roaming/Fatshark/Darktide/scores_history/v1/123.lua"
        sb.Mods.lua.io.open(fwd, "w")
        -- Backslash absolute path forwarded with backslashes preserved:
        local bwd = "C:\\Users\\example\\AppData\\Roaming\\Fatshark\\Darktide\\scores_history\\v1\\456.lua"
        sb.Mods.lua.io.open(bwd, "w")
        runner.assert_eq(2, #opened, "both absolute opens must reach the underlying io.open")
        runner.assert_eq(fwd, opened[1].p,
            "forward-slash absolute path must be forwarded verbatim (no rooting/normalization)")
        runner.assert_eq("w", opened[1].m, "mode forwarded")
        runner.assert_eq(bwd, opened[2].p,
            "backslash absolute path must be forwarded verbatim (backslashes preserved)")
    end)

    runner.register("io wrapper: internal Mods.file.* is NOT double-wrapped", function()
        -- Mods.file.dofile roots at _mod_root via its own resolve() and uses
        -- the raw _io captured BEFORE the wrapper installed. The wrapper must
        -- not intercept it. Verify by tracking the path the underlying io.open
        -- receives: it must be the forward-slash _mod_root-rooted path from
        -- resolve(), not a double-prefixed/backslash-normalized wrapper path.
        local opened_with = {}
        local files = { ["C:/staged/mods/inner.lua"] = "return 'ok'" }
        local sb = mock.new_sandbox()
        sb.Mods = {
            lua = {},
            _mod_path = "C:/staged",
            _mod_root = "C:/staged/mods",
        }
        local base_io = mock.make_io(files)
        sb.Mods.lua.io = {
            open = function(p, m) opened_with[#opened_with + 1] = p; return base_io.open(p, m) end,
            lines = base_io.lines,
        }
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function() end
        mock.run_module("file", sb)
        local v = sb.Mods.file.dofile("inner")
        runner.assert_eq("ok", v)
        runner.assert_eq(1, #opened_with, "dofile must open exactly once via the raw io")
        runner.assert_eq("C:/staged/mods/inner.lua", opened_with[1],
            "internal dofile must use the resolve()-produced forward-slash path, not a wrapper-normalized one")
    end)

    -- ---------------------------------------------------------------------
    -- Mods.lua.io.popen wrapper (raw-io redirection, shell-out surface)
    -- ---------------------------------------------------------------------
    --
    -- The popen wrapper prepends `cd /d "<normpath _mod_root>" && ` to the
    -- command string so relative-path shell-out calls resolve against the
    -- mods dir (the stock-DMF ..\mods\<mod>\... convention). It installs only
    -- when _mod_root is a non-empty string and Mods.lua.io.popen is a
    -- function. These tests use a recording popen mock to verify the
    -- command-string transformation only (no real cmd.exe is spawned).

    -- Build a wrapper-installed sandbox whose io.popen records what it
    -- receives. _mod_root is set only when mod_root ~= nil (pass nil or "" to
    -- exercise the no-install guard). Returns the sandbox + the record table.
    local function setup_with_popen(mod_root)
        local received = {}
        local sb = mock.new_sandbox()
        local mods = { lua = {}, _mod_path = "C:/staged" }
        if mod_root ~= nil then mods._mod_root = mod_root end
        sb.Mods = mods
        local iot = mock.make_io({})
        iot.popen = function(cmd, ...)
            received.cmd = cmd
            received.extra = { ... }
            return "FAKE_HANDLE"
        end
        sb.Mods.lua.io = iot
        sb.Mods.lua.loadstring = sb.loadstring
        sb.__print = function() end
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        mock.run_module("file", sb)
        return sb, received
    end

    runner.register("popen wrapper: prepends cd /d \"<normpath _mod_root>\" && to relative-path commands", function()
        -- The wrapper must prepend the cd /d prefix to the command string.
        -- Compute the expected prefix via path.normpath so the assertion is
        -- platform-correct in the offline harness (forward slashes on Linux,
        -- backslashes on Windows — matching what the wrapper produces).
        local path_mod = mock.run_module("path", mock.new_sandbox())
        local mod_root = "C:/staged/mods"
        local sb, received = setup_with_popen(mod_root)
        local h = sb.Mods.lua.io.popen("dir ..\\mods\\foo\\audio /b /a-d")
        runner.assert_eq("FAKE_HANDLE", h, "popen must return the original's result")
        local expected = 'cd /d "' .. path_mod.normpath(mod_root) .. '" && dir ..\\mods\\foo\\audio /b /a-d'
        runner.assert_eq(expected, received.cmd,
            "popen must prepend cd /d + normpath root to the command string")
    end)

    runner.register("popen wrapper: non-string cmd passes through to the original unmodified", function()
        -- A nil/non-string cmd bypasses the prepend (the wrapper only
        -- transforms strings) and reaches the original verbatim.
        local sb, received = setup_with_popen("C:/staged/mods")
        local h = sb.Mods.lua.io.popen(nil)
        runner.assert_eq("FAKE_HANDLE", h)
        runner.assert_eq(nil, received.cmd,
            "non-string cmd must reach the original unchanged (no prepend)")
    end)

    runner.register("popen wrapper: does not install when _mod_root is empty/nil (popen stays original)", function()
        -- The wrapper guard keys on _mod_root; with it missing or empty, the
        -- wrapper does not install and Mods.lua.io.popen is the original mock
        -- — the command reaches it unchanged.
        local sb_nil, received_nil = setup_with_popen(nil)
        runner.assert_eq("FAKE_HANDLE", sb_nil.Mods.lua.io.popen("dir foo"))
        runner.assert_eq("dir foo", received_nil.cmd, "nil _mod_root: popen must not be wrapped")

        local sb_empty, received_empty = setup_with_popen("")
        runner.assert_eq("FAKE_HANDLE", sb_empty.Mods.lua.io.popen("dir bar"))
        runner.assert_eq("dir bar", received_empty.cmd, "empty _mod_root: popen must not be wrapped")
    end)

    runner.register("popen wrapper: forwards trailing varargs (mode) to the original", function()
        -- io.popen(prog, mode): the wrapper forwards everything after cmd.
        local sb, received = setup_with_popen("C:/staged/mods")
        sb.Mods.lua.io.popen("dir foo", "r")
        runner.assert_eq({ "r" }, received.extra,
            "popen must forward trailing args (mode) to the original")
        runner.assert_truthy(received.cmd:find('^cd /d "'),
            "the forwarded command must still carry the cd prepend")
    end)
end
