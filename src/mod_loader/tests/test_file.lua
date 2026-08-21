-- test_file.lua — Mods.file.* behavior (src/mod_loader/file.lua).
--
-- Asserts the external behavior of the mod-root-rooted file operations:
--   - path validation: rejects absolute/UNC/drive/NUL/..; allows nested relative
--   - safe/unsafe distinction: safe returns false on failure, unsafe raises
--   - safe-op failure logging: a chunk that exists but fails to compile or
--     raises logs ONE ERROR diagnostic; missing-file/resolve/read failures
--     stay silent (mods probe for optional files via safe dofile returning
--     false)
--   - join form: the manager-slot (dir, name, ext) / (name, ext) argument
--     shapes — resolution, component validation, args pass-through, observers
--   - single-open: the handle is closed before compile/run and on read failure
--   - reads: raw content + trimmed line list (blank/comment skipped)
--   - observer isolation: observers fire only after successful exec, failures
--     are logged without replacing the chunk result
--   - the mods-in-game-tree gate: the io.open/lines + popen wrappers install
--     only when NOT gated (absent gate = today's behavior)

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

    -- Build a sandbox whose io.open records every path it receives (for
    -- asserting the exact path an op hands to io). Returns the sandbox + the
    -- record list.
    local function setup_recording(files)
        local sb = mock.new_sandbox()
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }
        local base_io = mock.make_io(files or {})
        local opened_with = {}
        sb.Mods.lua.io = {
            open = function(p, m) opened_with[#opened_with + 1] = p; return base_io.open(p, m) end,
            lines = base_io.lines,
        }
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function() end
        mock.attach_logger(sb)
        mock.run_module("file", sb)
        return sb, opened_with
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

    -- ---------------------------------------------------------------------
    -- Safe-op failure logging (execution failures log; probe misses stay silent)
    -- ---------------------------------------------------------------------

    -- Build a sandbox whose __print captures diagnostics (the leveled loggers
    -- route there via mock.attach_logger). file.lua must be loaded AFTER the
    -- logger attach (it captures log_error at module scope).
    local function setup_logging(files)
        local sb = mock.new_sandbox()
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }
        local logged = {}
        sb.Mods.lua.io = mock.make_io(files or {})
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        sb.__print = function(m) table.insert(logged, m) end
        mock.attach_logger(sb)
        mock.run_module("file", sb)
        return sb, logged
    end

    runner.register("file: safe dofile of a raising chunk returns false AND logs one ERROR line", function()
        local files = { [mock.MOD_ROOT .. "/boom.lua"] = "error('kaboom')" }
        local sb, logged = setup_logging(files)
        local v = sb.Mods.file.dofile("boom")
        runner.assert_eq(false, v, "safe dofile must still return false on a runtime raise")
        runner.assert_eq(1, #logged, "exactly one diagnostics line for the failure")
        runner.assert_truthy(logged[1]:find("^ERROR %[mod_loader%] chunk failed: ") ~= nil,
            "the line must be a leveled chunk-failure diagnostic")
        runner.assert_truthy(logged[1]:find(mock.MOD_ROOT .. "/boom%.lua") ~= nil,
            "the line must name the full path")
        runner.assert_truthy(logged[1]:find("kaboom") ~= nil,
            "the line must carry the error text")
        -- The boolean exec op routes through the same execute() seam.
        runner.assert_eq(false, sb.Mods.file.exec("boom"), "exec must fail safe too")
        runner.assert_eq(2, #logged, "exec logs the same single line for its own failure")
    end)

    runner.register("file: safe dofile of a missing file returns false and logs NOTHING", function()
        -- Probe semantics: a miss is not a failure to diagnose — mods probe for
        -- optional files via safe ops. resolve/read failures stay silent; only
        -- execution failures (an existing chunk that compiles/runs badly) log.
        local sb, logged = setup_logging({})
        runner.assert_eq(false, sb.Mods.file.dofile("nope/missing"))
        runner.assert_eq(false, sb.Mods.file.exec("nope/missing"))
        runner.assert_eq(false, sb.Mods.file.read_content("nope/missing"))
        runner.assert_eq(0, #logged, "a missing file must emit no diagnostics")
    end)

    runner.register("file: safe dofile of a syntax-broken chunk returns false AND logs", function()
        local files = { [mock.MOD_ROOT .. "/broken.lua"] = "this is not lua" }
        local sb, logged = setup_logging(files)
        local v, err = sb.Mods.file.dofile("broken")
        runner.assert_eq(false, v, "safe dofile must return false on a compile error")
        runner.assert_type("string", err, "the failure reason is still returned")
        runner.assert_eq(1, #logged, "exactly one diagnostics line for the compile failure")
        runner.assert_truthy(logged[1]:find("chunk failed: " .. mock.MOD_ROOT .. "/broken%.lua") ~= nil,
            "the line names the failing chunk")
        -- The unsafe variant raises BEFORE any logging (errors propagate, they
        -- are not tee'd through the safe-path diagnostic).
        local n = #logged
        local ok = pcall(sb.Mods.file.dofile_unsafe, "broken")
        runner.assert_eq(false, ok, "unsafe dofile must still raise on a compile error")
        runner.assert_eq(n, #logged, "the unsafe path must not add a diagnostics line")
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

    runner.register("file: dofile forwards non-string args to the chunk (path form)", function()
        -- Path-form args are any NON-string value: a string second argument
        -- is the join-form discriminator (asserted in the join-form section
        -- below).
        local files = { [mock.MOD_ROOT .. "/arg.lua"] = "local a = ... return type(a) == 'table' and a.tag or a" }
        local sb = setup(files)
        runner.assert_eq("hello", sb.Mods.file.dofile("arg", { tag = "hello" }),
            "table args must reach the chunk")
        runner.assert_eq(42, sb.Mods.file.dofile("arg", 42),
            "number args must reach the chunk")
        runner.assert_eq(nil, sb.Mods.file.dofile("arg", nil),
            "nil args are indistinguishable from no args (path form)")
    end)

    -- ---------------------------------------------------------------------
    -- Join form (the manager-slot argument shapes)
    -- ---------------------------------------------------------------------

    runner.register("file: 3-arg join form resolves <dir>/<name>.<ext> under the mod root", function()
        -- The AML manager-slot call: exec_with_return(folder, folder, "mod").
        -- The io mock must receive exactly the resolve()-rooted joined path
        -- (no .lua append — the joined basename already has an extension).
        local files = { [mock.MOD_ROOT .. "/MyMod/MyMod.mod"] = "return 'mod-data'" }
        local sb, opened_with = setup_recording(files)
        local v = sb.Mods.file.exec_with_return("MyMod", "MyMod", "mod")
        runner.assert_eq("mod-data", v, "3-arg join must exec the joined file")
        runner.assert_eq(1, #opened_with, "the joined file must be opened exactly once")
        runner.assert_eq(mock.MOD_ROOT .. "/MyMod/MyMod.mod", opened_with[1],
            "io.open must receive <mod_root>/<dir>/<name>.<ext>")
    end)

    runner.register("file: 2-arg join form (name, ext) works across the family", function()
        local files = {
            [mock.MOD_ROOT .. "/dmf.mod"] = "return 'dmf-data'",
            [mock.MOD_ROOT .. "/order.lst"] = "alpha\nbeta\n",
            [mock.MOD_ROOT .. "/raw.txt"] = "raw-content",
        }
        local sb = setup(files)
        runner.assert_eq("dmf-data", sb.Mods.file.exec_with_return("dmf", "mod"))
        runner.assert_eq("dmf-data", sb.Mods.file.dofile("dmf", "mod"))
        runner.assert_eq("dmf-data", sb.Mods.file.exec_unsafe_with_return("dmf", "mod"))
        runner.assert_eq(true, sb.Mods.file.exec("dmf", "mod"))
        runner.assert_eq({ "alpha", "beta" }, sb.Mods.file.read_content_to_table("order", "lst"),
            "read_content_to_table(name, ext) must read <name>.<ext>")
        runner.assert_eq("raw-content", sb.Mods.file.read_content("raw", "txt"),
            "read_content(name, ext) must read <name>.<ext>")
    end)

    runner.register("file: 4-arg join form passes args through to the chunk", function()
        local files = {
            [mock.MOD_ROOT .. "/cfg/data.lua"] = "local a = ... if a == nil then return 'nil-args' end return a.tag",
        }
        local sb = setup(files)
        runner.assert_eq("hi", sb.Mods.file.exec_with_return("cfg", "data", "lua", { tag = "hi" }),
            "the 4th join-form argument must be the chunk argument")
        runner.assert_eq("nil-args", sb.Mods.file.exec_with_return("cfg", "data", "lua"),
            "without a 4th argument the chunk receives nil args")
    end)

    runner.register("file: a string second argument selects the join form", function()
        -- (path, "string") is the join form: name=path, ext=string — NOT the
        -- path form with string args. Both candidate targets are staged; only
        -- the join interpretation can produce this result.
        local files = {
            [mock.MOD_ROOT .. "/notes.txt"] = "return 'from-join'",
            [mock.MOD_ROOT .. "/notes.lua"] = "return 'from-path'",
        }
        local sb = setup(files)
        runner.assert_eq("from-join", sb.Mods.file.dofile("notes", "txt"),
            "(path, string) must join to <path>.<string>, not pass the string as chunk args")
    end)

    runner.register("file: join-form miss returns false (safe) and raises (unsafe)", function()
        local sb = setup({})
        runner.assert_eq(false, sb.Mods.file.exec_with_return("MyMod", "MyMod", "mod"),
            "safe join-form exec must return false on a missing file")
        local ok = pcall(sb.Mods.file.exec_unsafe_with_return, "MyMod", "MyMod", "mod")
        runner.assert_eq(false, ok, "unsafe join-form exec must raise on a missing file")
    end)

    runner.register("file: join-form components must be single segments (validation matrix)", function()
        -- Every bad component value, in each join position, must fail the
        -- safe ops (false) and raise in the unsafe ops.
        local sb = setup({})
        local bad = { "", "..", "a/b", "a\\b", "a:b" }
        for i = 1, #bad do
            local v = bad[i]
            local r, reason = sb.Mods.file.exec_with_return(v, "name", "mod")
            runner.assert_eq(false, r, "bad dir component must fail safe: '" .. v .. "'")
            runner.assert_type("string", reason, "safe failure must carry a reason: '" .. v .. "'")
            runner.assert_eq(false, sb.Mods.file.exec_with_return("dir", v, "mod"),
                "bad name component must fail safe: '" .. v .. "'")
            runner.assert_eq(false, sb.Mods.file.exec_with_return("name", v),
                "bad ext component (2-arg join) must fail safe: '" .. v .. "'")
            runner.assert_eq(false, sb.Mods.file.exec("dir", v, "mod"),
                "boolean exec must fail safe: '" .. v .. "'")
            runner.assert_eq(false, sb.Mods.file.read_content("dir", v),
                "read_content must fail safe: '" .. v .. "'")
            runner.assert_eq(false, pcall(sb.Mods.file.exec_unsafe_with_return, "dir", v, "mod"),
                "bad component must raise unsafe: '" .. v .. "'")
        end
        -- Non-string components fail too. (A non-string SECOND argument is
        -- path form, not a bad component — so ext is only testable non-string
        -- in the 3-arg shape.)
        runner.assert_eq(false, sb.Mods.file.exec_with_return(42, "name", "mod"),
            "non-string dir component must fail")
        runner.assert_eq(false, sb.Mods.file.exec_with_return("dir", "name", 42),
            "non-string ext component must fail")
        runner.assert_eq(false, pcall(sb.Mods.file.exec_unsafe_with_return, 42, "name", "mod"),
            "non-string dir component must raise unsafe")
    end)

    runner.register("file: observers fire exactly once after a successful join-form exec", function()
        local files = { [mock.MOD_ROOT .. "/MyMod/MyMod.mod"] = "return 'mod-data'" }
        local sb = setup(files)
        local fired = 0
        local seen = {}
        sb.Mods.file.add_observer(function(rel, args, result)
            fired = fired + 1
            seen = { rel = rel, args = args, result = result }
        end)
        local v = sb.Mods.file.exec_with_return("MyMod", "MyMod", "mod")
        runner.assert_eq("mod-data", v)
        runner.assert_eq(1, fired, "observer must fire exactly once after a successful join-form exec")
        runner.assert_eq("MyMod/MyMod.mod", seen.rel,
            "observer rel_path is the joined mod-relative path")
        runner.assert_eq(nil, seen.args, "no chunk args -> observer args nil")
        runner.assert_eq("mod-data", seen.result)
        -- A failed join-form exec must not fire the observer again.
        sb.Mods.file.exec_with_return("MyMod", "Missing", "mod")
        runner.assert_eq(1, fired, "observer must not fire on a failed join-form exec")
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
        mock.attach_logger(sb)
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
        mock.attach_logger(sb)
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
        mock.attach_logger(sb)
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
        mock.attach_logger(sb)
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
    -- absolute paths verbatim. These tests use the
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
        mock.attach_logger(sb)
        mock.run_module("file", sb)
        local f, err = sb.Mods.lua.io.open(rel)
        runner.assert_eq(expected, opened_with,
            "underlying io.open must receive the normpath-resolved rooted path (rooted + forwarded)")
        runner.assert_nil(f, "the file is not staged, so the underlying io.open returns nil (normal miss)")
        runner.assert_truthy(err ~= nil, "the miss carries io.open's own err string (the wrapper did not reject)")
    end)

    runner.register("io wrapper: sibling-prefix path resolves + forwards (rooting only)", function()
        -- ./../mods_evil/foo from _mod_root (C:/staged/mods) normpaths to
        -- C:/staged/mods_evil/foo. The wrapper roots + forwards the path;
        -- whether the open then succeeds depends on whether the file is staged
        -- (normal io.open failure shape on a miss). This test stages the file
        -- and verifies the open reaches it.
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
        mock.attach_logger(sb)
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
        mock.attach_logger(sb)
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
        mock.attach_logger(sb)
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
        mock.attach_logger(sb)
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

    -- ---------------------------------------------------------------------
    -- Mods-in-game-tree gate (Mods._relay.mods_in_game_tree)
    -- ---------------------------------------------------------------------
    --
    -- When the mod path IS the game directory (launcher-derived; init.lua
    -- snapshots the trampoline global before file.lua loads), ALL raw-io
    -- retargeting stays off: the open/lines wrapper AND the popen
    -- cd-prepend must NOT install — stock DMF conventions resolve naturally
    -- from binaries/. An absent gate (no Mods._relay, or the field nil)
    -- means NOT gated = today's behavior (wrappers install).

    -- Build a sandbox with explicit gate control. gate is true/false, or
    -- "absent" (no Mods._relay at all). mod_root defaults to a set root;
    -- pass "" to exercise the empty-root + gate-on combination. files
    -- optionally backs the io mock (path -> content) so rooted opens resolve.
    -- Captures the raw io functions the sandbox provided so identity
    -- comparison proves no wrap. Returns (sb, raw) where raw =
    -- { open, lines, popen }.
    local function setup_gated(gate, mod_root, files)
        local sb = mock.new_sandbox()
        local mods = {
            lua = {},
            _mod_path = "C:/staged",
            _mod_root = mod_root or "C:/staged/mods",
        }
        if gate ~= "absent" then
            mods._relay = { mods_in_game_tree = gate }
        end
        sb.Mods = mods
        local iot = mock.make_io(files or {})
        iot.popen = function() return "FAKE_HANDLE" end
        local raw = { open = iot.open, lines = iot.lines, popen = iot.popen }
        sb.Mods.lua.io = iot
        sb.Mods.lua.loadstring = sb.loadstring
        sb.__print = function() end
        mock.attach_logger(sb)
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end
        mock.run_module("file", sb)
        return sb, raw
    end

    runner.register("io gate: game-tree mods skip open/lines + popen wrapping (raw identities)", function()
        local sb, raw = setup_gated(true)
        runner.assert_eq(raw.open, sb.Mods.lua.io.open,
            "io.open must stay the raw original under the gate")
        runner.assert_eq(raw.lines, sb.Mods.lua.io.lines,
            "io.lines must stay the raw original under the gate")
        runner.assert_eq(raw.popen, sb.Mods.lua.io.popen,
            "io.popen must stay the raw original under the gate")
    end)

    runner.register("io gate: gate explicitly false installs the wrappers (today's behavior)", function()
        local sb, raw = setup_gated(false)
        runner.assert_truthy(raw.open ~= sb.Mods.lua.io.open, "io.open must be wrapped")
        runner.assert_truthy(raw.lines ~= sb.Mods.lua.io.lines, "io.lines must be wrapped")
        runner.assert_truthy(raw.popen ~= sb.Mods.lua.io.popen, "io.popen must be wrapped")
    end)

    runner.register("io gate: no Mods._relay at all installs the wrappers (nil-safe)", function()
        local sb, raw = setup_gated("absent")
        runner.assert_truthy(raw.open ~= sb.Mods.lua.io.open,
            "an absent Mods._relay means not gated (io.open wraps)")
        runner.assert_truthy(raw.lines ~= sb.Mods.lua.io.lines,
            "an absent Mods._relay means not gated (io.lines wraps)")
        runner.assert_truthy(raw.popen ~= sb.Mods.lua.io.popen,
            "an absent Mods._relay means not gated (io.popen wraps)")
    end)

    runner.register("io gate: game-tree mods + empty _mod_root installs nothing (both conditions required)", function()
        local sb, raw = setup_gated(true, "")
        runner.assert_eq(raw.open, sb.Mods.lua.io.open,
            "empty _mod_root: io.open never wraps (gate or not)")
        runner.assert_eq(raw.lines, sb.Mods.lua.io.lines,
            "empty _mod_root: io.lines never wraps")
        runner.assert_eq(raw.popen, sb.Mods.lua.io.popen,
            "empty _mod_root: io.popen never wraps")
    end)

    runner.register("io gate: game-tree mods + gate ON — Mods.file.* still resolves at _mod_root", function()
        -- The gate disables only the io wrappers (Mods.lua.io.open/io.lines/io.popen).
        -- Mods.file.* (used by the manager and the manager-slot convention) still
        -- roots at _mod_root — which is GAME_DIR\mods in game-tree mode.
        -- This is the not-gated scope decision: the wrappers are off, but the
        -- internal rooting is unchanged. The gate is present BEFORE file.lua
        -- evaluates (the setup_gated shape, with real file backing), so gating
        -- Mods.file.* at module load would break the rooted open and fail this.
        local mod_root = "C:/staged/mods"
        local files = { [mod_root .. "/test.lua"] = "return 'game-tree-mods'" }
        local sb = setup_gated(true, mod_root, files)
        -- Verify Mods.file.dofile still resolves from _mod_root under the gate.
        local v = sb.Mods.file.dofile("test")
        runner.assert_eq("game-tree-mods", v,
            "Mods.file.dofile must still resolve from _mod_root under the gate")
    end)
end
