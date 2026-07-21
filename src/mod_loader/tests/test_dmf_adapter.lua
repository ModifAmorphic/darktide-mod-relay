-- test_dmf_adapter.lua — the stock-DMF compatibility boundary
-- (src/mod_loader/dmf_adapter.lua).
--
-- Asserts the adapter's public contract:
--   - establishes the DMF-visible manager shape (Managers.mod publication,
--     _settings.developer_mode=false, nil _state/_mod_load_index);
--   - explicit current-entry transitions + done transition (the manager never
--     writes DMF contract fields directly);
--   - DMF-required entry-shape validation (success + failure reasons);
--   - registers the Mods.file observer exactly once per adapter;
--   - installation-aware IO adaptation: a re-fire no-ops ONLY when both the
--     DMFMod table identity AND the exact Relay-installed io_dofile wrapper
--     still match; a genuinely new table adapts once io_dofile is a function;
--     the SAME table whose io_dofile was overwritten (core/io.lua on a reused
--     class table) re-adapts all eight; retire RETAINS the markers; no
--     fabrication when DMF absent;
--   - the eight DMFMod:io_* overrides: exact safe/unsafe routing, path
--     construction + default .lua extension, safe failure return + DMF error
--     logging, unsafe error propagation (no swallow), graceful missing
--     debug/error methods on the mod object.
--
-- The adapter is a plain module (not a class). It writes the manager's physical
-- DMF-visible fields directly; stock DMF keeps reading them off `Managers.mod`.

local mock = require("mock")

return function(runner)
    -- Build a sandbox with the surfaces dmf_adapter.lua touches: __print and
    -- Mods.file.add_observer. opts customizes Mods.file (recording IO ops +
    -- an observer list with a notify helper). Returns (sb, adapter_module).
    local function setup(opts)
        opts = opts or {}
        local sb = mock.new_sandbox()
        sb.__print = opts.print or function() end
        sb.Managers = opts.managers or {}
        local observers = opts.observers_local
        sb.Mods = { file = {} }
        if opts.with_observer_list then
            observers = {}
            sb.Mods.file.add_observer = function(fn)
                observers[#observers + 1] = fn
            end
            sb.Mods.file.notify = function(rel, args, result)
                for i = 1, #observers do
                    observers[i](rel, args, result)
                end
            end
        elseif opts.add_observer_fn then
            sb.Mods.file.add_observer = opts.add_observer_fn
        else
            sb.Mods.file.add_observer = function() end
        end
        -- class_registry owns the _G[class_name] retire surface (production
        -- loads it before dmf_adapter). Seed the contract so retire routes
        -- DMFMod through Mods.retire_class.
        sb.Mods.retire_class = function(name)
            if type(name) == "string" then sb[name] = nil end
        end
        local adapter_module = mock.run_module("dmf_adapter", sb)
        return sb, adapter_module, observers
    end

    -- A plain fake manager: a table the adapter writes DMF-visible fields onto.
    local function fake_manager()
        return {}
    end

    -- Install recording Mods.file.* ops that capture (op -> "R:<op>" return).
    -- Returns the table of installed ops so each test can read call records.
    local function install_recording_file_ops(sb)
        local calls = {}
        for _, m in ipairs({ "dofile", "dofile_unsafe", "exec", "exec_unsafe",
                             "exec_with_return", "exec_unsafe_with_return",
                             "read_content", "read_content_to_table" }) do
            sb.Mods.file[m] = function(path, args)
                table.insert(calls, m .. ":" .. path)
                return "R:" .. m
            end
        end
        return calls
    end

    -- The full DMFMod surface as DMF's core/io.lua would install it (eight
    -- io_* methods, optionally debug/error).
    local function full_dmfmod_surface()
        return {
            io_dofile = function() end,
            io_dofile_unsafe = function() end,
            io_exec = function() end, io_exec_unsafe = function() end,
            io_exec_with_return = function() end, io_exec_unsafe_with_return = function() end,
            io_read_content = function() end, io_read_content_to_table = function() end,
        }
    end

    -- ---------------------------------------------------------------------
    -- Adapter contract: establish() publishes the manager + default fields
    -- ---------------------------------------------------------------------

    runner.register("dmf_adapter: establish publishes Managers.mod = manager", function()
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        runner.assert_eq(manager, sb.Managers.mod, "establish publishes Managers.mod")
    end)

    runner.register("dmf_adapter: establish preserves an existing Managers table", function()
        local pre = { other = {} }
        local sb, M = setup({ managers = pre })
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        runner.assert_eq(pre, sb.Managers, "establish must not replace Managers wholesale")
        runner.assert_eq(manager, sb.Managers.mod)
        runner.assert_eq(pre.other, sb.Managers.other)
    end)

    runner.register("dmf_adapter: establish sets _settings.developer_mode = false", function()
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        runner.assert_type("table", manager._settings)
        runner.assert_eq(false, manager._settings.developer_mode,
            "startup default is developer_mode=false")
    end)

    runner.register("dmf_adapter: establish leaves _state and _mod_load_index nil", function()
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        runner.assert_nil(manager._state, "_state is nil before any load completes")
        runner.assert_nil(manager._mod_load_index, "_mod_load_index is nil initially")
    end)

    runner.register("dmf_adapter: establish is idempotent (re-defaults fields)", function()
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        -- Simulate the manager mid-load: state/index set to non-nil.
        manager._mod_load_index = 2
        manager._state = "intermediate"
        adapter:establish()
        runner.assert_nil(manager._mod_load_index, "re-establish clears _mod_load_index")
        runner.assert_nil(manager._state, "re-establish clears _state")
        runner.assert_eq(false, manager._settings.developer_mode)
    end)

    -- ---------------------------------------------------------------------
    -- Adapter contract: explicit transitions (manager never writes DMF fields)
    -- ---------------------------------------------------------------------

    runner.register("dmf_adapter: begin_load_entry/end_load_pass drive _mod_load_index", function()
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        runner.assert_nil(manager._mod_load_index)
        adapter:begin_load_entry(1)
        runner.assert_eq(1, manager._mod_load_index)
        adapter:begin_load_entry(3)
        runner.assert_eq(3, manager._mod_load_index)
        adapter:end_load_pass()
        runner.assert_nil(manager._mod_load_index, "end_load_pass clears the index")
    end)

    runner.register("dmf_adapter: mark_load_done sets _state='done'", function()
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        runner.assert_nil(manager._state)
        adapter:mark_load_done()
        runner.assert_eq("done", manager._state)
    end)

    runner.register("dmf_adapter: _state stays nil until mark_load_done", function()
        -- begin/end of entries must NOT publish _state. Only mark_load_done does.
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        adapter:begin_load_entry(1)
        runner.assert_nil(manager._state, "_state still nil mid-load")
        adapter:end_load_pass()
        runner.assert_nil(manager._state, "_state still nil after the pass completes")
        adapter:mark_load_done()
        runner.assert_eq("done", manager._state)
    end)

    -- ---------------------------------------------------------------------
    -- Adapter contract: entry-shape validation at the load boundary
    -- ---------------------------------------------------------------------

    runner.register("dmf_adapter: validate_entry accepts well-formed entries", function()
        local sb, M = setup()
        local adapter = M.new(fake_manager())
        local ok, reason = adapter:validate_entry({ id = 1, name = "alpha", handle = "alpha" })
        runner.assert_eq(true, ok)
        runner.assert_nil(reason)
    end)

    runner.register("dmf_adapter: validate_entry accepts a string handle distinct from name", function()
        local sb, M = setup()
        local adapter = M.new(fake_manager())
        local ok = adapter:validate_entry({ id = 7, name = "x", handle = "x-user" })
        runner.assert_eq(true, ok)
    end)

    runner.register("dmf_adapter: validate_entry rejects missing id", function()
        local sb, M = setup()
        local adapter = M.new(fake_manager())
        local ok, reason = adapter:validate_entry({ name = "x", handle = "x" })
        runner.assert_eq(false, ok)
        runner.assert_truthy(reason and reason:find("id") ~= nil,
            "reason should name the missing id field")
    end)

    runner.register("dmf_adapter: validate_entry rejects non-string name", function()
        local sb, M = setup()
        local adapter = M.new(fake_manager())
        local ok, reason = adapter:validate_entry({ id = 1, name = 5, handle = "x" })
        runner.assert_eq(false, ok)
        runner.assert_truthy(reason and reason:find("name") ~= nil)
    end)

    runner.register("dmf_adapter: validate_entry rejects missing handle", function()
        local sb, M = setup()
        local adapter = M.new(fake_manager())
        local ok, reason = adapter:validate_entry({ id = 1, name = "x" })
        runner.assert_eq(false, ok)
        runner.assert_truthy(reason and reason:find("handle") ~= nil)
    end)

    runner.register("dmf_adapter: validate_entry rejects nil entry", function()
        local sb, M = setup()
        local adapter = M.new(fake_manager())
        local ok = adapter:validate_entry(nil)
        runner.assert_eq(false, ok)
    end)

    -- ---------------------------------------------------------------------
    -- Adapter contract: observer registration exactly once
    -- ---------------------------------------------------------------------

    runner.register("dmf_adapter: register_io_observer registers exactly once", function()
        local add_calls = 0
        local sb, M = setup({ add_observer_fn = function() add_calls = add_calls + 1 end })
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        adapter:register_io_observer()
        adapter:register_io_observer()
        runner.assert_eq(1, add_calls, "add_observer must be called exactly once per adapter")
    end)

    runner.register("dmf_adapter: register_io_observer is a no-op when Mods.file is absent", function()
        local sb, M = setup({ add_observer_fn = function() end })
        sb.Mods.file = nil  -- simulate the surface not being ready
        local adapter = M.new(fake_manager())
        local ok, err = pcall(function() adapter:register_io_observer() end)
        runner.assert_eq(true, ok, "missing Mods.file must not raise: " .. tostring(err))
    end)

    runner.register("dmf_adapter: registered observer triggers adaptation on DMFMod surface", function()
        local sb, M, observers = setup({ with_observer_list = true })
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        runner.assert_nil(adapter:adapted_dmfmod(), "nothing adapted before DMFMod exists")
        runner.assert_nil(sb.DMFMod, "no DMFMod fabricated by registration")
        -- Simulate DMF's core/io.lua surfacing DMFMod with io_* methods, then
        -- file.lua notifying observers after that successful exec.
        sb.DMFMod = full_dmfmod_surface()
        sb.Mods.file.notify()
        runner.assert_eq(sb.DMFMod, adapter:adapted_dmfmod(),
            "observer fire adapts the now-surfaced DMFMod")
    end)

    -- ---------------------------------------------------------------------
    -- Installation-aware IO adaptation (table + Relay-wrapper identity).
    -- Same-table-same-wrapper re-fire is idempotent; a new table adapts; the
    -- same table whose io_dofile was overwritten re-adapts. See also the
    -- retire-RETAINS + same-table-reuse regression tests near the end.
    -- ---------------------------------------------------------------------

    runner.register("dmf_adapter: same DMFMod table re-fire is idempotent", function()
        local sb, M, observers = setup({ with_observer_list = true })
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.DMFMod = full_dmfmod_surface()
        sb.Mods.file.notify()
        local first_io_dofile = sb.DMFMod.io_dofile
        runner.assert_eq(sb.DMFMod, adapter:adapted_dmfmod())
        -- Re-fire (file observer fires on every successful exec).
        sb.Mods.file.notify()
        sb.Mods.file.notify()
        runner.assert_eq(first_io_dofile, sb.DMFMod.io_dofile,
            "same DMFMod table must not be re-adapted")
        runner.assert_eq(sb.DMFMod, adapter:adapted_dmfmod())
    end)

    runner.register("dmf_adapter: a NEW DMFMod table is re-adapted on the next fire", function()
        local sb, M, observers = setup({ with_observer_list = true })
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        -- Generation 1.
        sb.DMFMod = full_dmfmod_surface()
        sb.Mods.file.notify()
        local gen1 = sb.DMFMod
        local gen1_io_dofile = gen1.io_dofile
        runner.assert_eq(gen1, adapter:adapted_dmfmod())
        -- Generation 2: stock DMF redefines the class (e.g. on hot reload).
        -- io_dofile is again the stock surface (the adapter must override it).
        sb.DMFMod = full_dmfmod_surface()
        runner.assert_truthy(gen1 ~= sb.DMFMod, "sanity: gen2 is a distinct table")
        runner.assert_truthy(gen1_io_dofile ~= sb.DMFMod.io_dofile,
            "sanity: gen2's stock io_dofile is a distinct function")
        sb.Mods.file.notify()
        runner.assert_eq(sb.DMFMod, adapter:adapted_dmfmod(),
            "the new generation is now the adapted table")
        runner.assert_truthy(gen1_io_dofile ~= sb.DMFMod.io_dofile,
            "gen2's io_dofile is the adapter override, not its stock surface")
        runner.assert_truthy(gen1.io_dofile ~= sb.DMFMod.io_dofile,
            "gen1's adapted method is not reused verbatim on gen2")
        -- Calling through gen2 routes to Mods.file (proven by the routing tests
        -- below); here we only assert the table identity advanced.
    end)

    runner.register("dmf_adapter: no DMFMod fabrication when DMFMod never surfaces", function()
        local sb, M, observers = setup({ with_observer_list = true })
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.Mods.file.notify()
        sb.Mods.file.notify()
        runner.assert_nil(sb.DMFMod, "observer must not fabricate DMFMod")
        runner.assert_nil(adapter:adapted_dmfmod())
    end)

    runner.register("dmf_adapter: no adaptation until io_dofile is a function", function()
        local sb, M, observers = setup({ with_observer_list = true })
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        -- DMFMod table exists, but core/io.lua has not installed io_dofile yet.
        sb.DMFMod = { not_yet = true }
        sb.Mods.file.notify()
        runner.assert_nil(adapter:adapted_dmfmod(),
            "must wait for io_dofile to be a function before adapting")
        -- Now install the surface and fire again.
        sb.DMFMod.io_dofile = function() end
        sb.Mods.file.notify()
        runner.assert_eq(sb.DMFMod, adapter:adapted_dmfmod())
    end)

    -- ---------------------------------------------------------------------
    -- DMF IO unit coverage: safe/unsafe routing for all eight methods
    -- ---------------------------------------------------------------------

    runner.register("dmf_adapter: io_* safe->safe and unsafe->unsafe routing", function()
        local sb, M, observers = setup({ with_observer_list = true })
        local calls = install_recording_file_ops(sb)
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.DMFMod = full_dmfmod_surface()
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        runner.assert_eq("R:dofile", inst:io_dofile("some/path"))
        runner.assert_eq("R:dofile_unsafe", inst:io_dofile_unsafe("some/path"))
        runner.assert_eq("R:exec", inst:io_exec("lp", "fn", "ext", "args"))
        runner.assert_eq("R:exec_unsafe", inst:io_exec_unsafe("lp", "fn", "ext", "args"))
        runner.assert_eq("R:exec_with_return", inst:io_exec_with_return("lp", "fn", "ext"))
        runner.assert_eq("R:exec_unsafe_with_return", inst:io_exec_unsafe_with_return("lp", "fn", "ext"))
        runner.assert_eq("R:read_content", inst:io_read_content("path", "ext"))
        runner.assert_eq("R:read_content_to_table", inst:io_read_content_to_table("path", "ext"))
        -- All eight methods routed (each exactly once for this set of calls).
        local seen = {}
        for _, c in ipairs(calls) do
            local op = c:match("^([%w_]+):")
            seen[op] = (seen[op] or 0) + 1
        end
        for _, op in ipairs({ "dofile", "dofile_unsafe", "exec", "exec_unsafe",
                              "exec_with_return", "exec_unsafe_with_return",
                              "read_content", "read_content_to_table" }) do
            runner.assert_eq(1, seen[op], "op " .. op .. " routed exactly once")
        end
    end)

    runner.register("dmf_adapter: io_dofile_unsafe routes to file.dofile_unsafe (NOT safe)", function()
        -- Negative assertion: the unsafe DMF method must NOT delegate to the
        -- safe file op. Verify by having the unsafe op raise.
        local sb, M, observers = setup({ with_observer_list = true })
        sb.Mods.file.dofile = function() return "SAFE" end
        sb.Mods.file.dofile_unsafe = function(p) error("unsafe-target:" .. p) end
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.DMFMod = { io_dofile = function() end, io_dofile_unsafe = function() end }
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        local ok, err = pcall(function() inst:io_dofile_unsafe("some/path") end)
        runner.assert_eq(false, ok, "io_dofile_unsafe must delegate to dofile_unsafe (which raised)")
        runner.assert_truthy(tostring(err):find("unsafe%-target") ~= nil,
            "must route through the unsafe op, not the safe one")
    end)

    runner.register("dmf_adapter: io_dofile appends default .lua extension", function()
        local sb, M, observers = setup({ with_observer_list = true })
        local calls = install_recording_file_ops(sb)
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.DMFMod = full_dmfmod_surface()
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        inst:io_dofile("some/path")
        local dofile_call
        for _, c in ipairs(calls) do
            if c:find("^dofile:") then dofile_call = c; break end
        end
        runner.assert_eq("dofile:some/path.lua", dofile_call,
            "io_dofile builds path with default .lua extension")
    end)

    runner.register("dmf_adapter: io_exec composes local_path/file_name/extension", function()
        local sb, M, observers = setup({ with_observer_list = true })
        local calls = install_recording_file_ops(sb)
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.DMFMod = full_dmfmod_surface()
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        inst:io_exec("scripts/mods", "data", "json", "args")
        local exec_call
        for _, c in ipairs(calls) do
            if c:find("^exec:") then exec_call = c; break end
        end
        runner.assert_eq("exec:scripts/mods/data.json", exec_call,
            "io_exec joins local_path/file_name/extension")
    end)

    runner.register("dmf_adapter: io_exec defaults extension to lua when absent", function()
        local sb, M, observers = setup({ with_observer_list = true })
        local calls = install_recording_file_ops(sb)
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.DMFMod = full_dmfmod_surface()
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        inst:io_exec("scripts/mods", "run")
        local exec_call
        for _, c in ipairs(calls) do
            if c:find("^exec:") then exec_call = c; break end
        end
        runner.assert_eq("exec:scripts/mods/run.lua", exec_call,
            "io_exec appends .lua when extension is absent")
    end)

    -- ---------------------------------------------------------------------
    -- DMF IO developer-facing logging
    -- ---------------------------------------------------------------------

    runner.register("dmf_adapter: adapted io_dofile emits DMF debug 'Loading' before the op", function()
        local sb, M, observers = setup({ with_observer_list = true })
        sb.Mods.file.dofile = function() return "ok" end
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        local debug_msgs = {}
        sb.DMFMod = {
            io_dofile = function() end,
            debug = function(self, msg) table.insert(debug_msgs, msg) end,
        }
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        inst:io_dofile("some/path")
        runner.assert_truthy(#debug_msgs >= 1, "debug called before the op")
        runner.assert_truthy(debug_msgs[1]:find("Loading") ~= nil,
            "debug message is a Loading line")
        runner.assert_truthy(debug_msgs[1]:find("some/path") ~= nil,
            "debug message includes the relative path")
    end)

    runner.register("dmf_adapter: safe failure emits DMF error naming the path; returns false", function()
        local sb, M, observers = setup({ with_observer_list = true })
        sb.Mods.file.dofile = function() return false end  -- Relay safe failure
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        local error_msgs = {}
        sb.DMFMod = {
            io_dofile = function() end,
            error = function(self, msg) table.insert(error_msgs, msg) end,
        }
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        local result = inst:io_dofile("missing/file")
        runner.assert_eq(false, result, "safe failure returns false unchanged")
        runner.assert_truthy(#error_msgs >= 1, "DMF error must be called on safe failure")
        runner.assert_truthy(error_msgs[1]:find("missing/file") ~= nil,
            "error message names the failing relative path")
    end)

    runner.register("dmf_adapter: safe success does NOT emit a DMF error", function()
        local sb, M, observers = setup({ with_observer_list = true })
        sb.Mods.file.dofile = function() return "value" end
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        local errors = 0
        sb.DMFMod = {
            io_dofile = function() end,
            error = function() errors = errors + 1 end,
        }
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        inst:io_dofile("ok/path")
        runner.assert_eq(0, errors, "no DMF error on safe success")
    end)

    runner.register("dmf_adapter: unsafe op logs debug but preserves throwing", function()
        local sb, M, observers = setup({ with_observer_list = true })
        sb.Mods.file.dofile_unsafe = function(p) error("propagated:" .. p) end
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        local debug_msgs = {}
        local errors = 0
        sb.DMFMod = {
            io_dofile = function() end,  -- the surface-present signal
            io_dofile_unsafe = function() end,
            debug = function(self, msg) table.insert(debug_msgs, msg) end,
            error = function() errors = errors + 1 end,
        }
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        local ok, err = pcall(function() inst:io_dofile_unsafe("throws/path") end)
        runner.assert_eq(false, ok, "unsafe op must propagate the error (not swallow)")
        runner.assert_truthy(tostring(err):find("propagated") ~= nil, "the original error surfaces")
        runner.assert_truthy(#debug_msgs >= 1, "debug must still be logged before the throw")
        runner.assert_eq(0, errors, "DMF error must NOT be called (throwing IS the error signal)")
    end)

    runner.register("dmf_adapter: no debug/error logging when DMFMod lacks those methods (graceful)", function()
        -- If the DMF mod object doesn't expose :debug()/:error(), the adapted
        -- methods still work — they just skip the logging. No raise.
        local sb, M, observers = setup({ with_observer_list = true })
        sb.Mods.file.dofile = function() return "val" end
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.DMFMod = { io_dofile = function() end }  -- no debug/error methods
        sb.Mods.file.notify()
        local inst = setmetatable({}, { __index = sb.DMFMod })
        local ok, result = pcall(function() return inst:io_dofile("x") end)
        runner.assert_eq(true, ok, "must not raise when DMFMod lacks debug/error")
        runner.assert_eq("val", result)
    end)

    -- ---------------------------------------------------------------------
    -- Cross-module integration: real file.lua + adapter observer timing
    -- ---------------------------------------------------------------------

    runner.register("dmf_adapter: real file.lua observer timing — adapts after core/io.lua exec", function()
        -- Load the REAL file.lua into a sandbox, register a real observer
        -- through the adapter, then execute a chunk that surfaces DMFMod via
        -- real Mods.file.dofile. The observer must fire after that successful
        -- exec and adapt BEFORE any Phase-2 call uses the method.
        local sb = mock.new_sandbox()
        sb.__print = function() end
        sb.Managers = {}
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }

        local files = {}
        -- A synthetic chunk that, when executed, surfaces DMFMod with its io_*
        -- methods (mirrors what DMF's core/io.lua does, without copying DMF).
        files[mock.MOD_ROOT .. "/dmf/core/io.lua"] = table.concat({
            "DMFMod = {}",
            "function DMFMod:io_dofile(p) return 'WRONG:' .. p end",
            "function DMFMod:io_dofile_unsafe(p) error('WRONG_UNSAFE:' .. p) end",
        }, "\n")
        -- A real lua chunk the adapted io_dofile will delegate to.
        files[mock.MOD_ROOT .. "/delegated.lua"] = "return 'delegated-value'"
        -- A real lua chunk that raises, for the unsafe routing check.
        files[mock.MOD_ROOT .. "/throws.lua"] = "error('chunk-throws')"

        sb.Mods.lua.io = mock.make_io(files)
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end

        -- Load real file.lua first (provides the real observer host surface).
        mock.run_module("file", sb)
        -- Then load the adapter module.
        local M = mock.run_module("dmf_adapter", sb)

        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        adapter:register_io_observer()
        runner.assert_nil(adapter:adapted_dmfmod(), "not yet adapted")

        -- Execute the DMFMod-surfacing chunk through real Mods.file.dofile.
        -- file.lua notifies the real observer after the successful exec, which
        -- triggers adaptation BEFORE any Phase-2 call uses the method.
        sb.Mods.file.dofile("dmf/core/io")
        runner.assert_eq(sb.DMFMod, adapter:adapted_dmfmod(),
            "real observer fired + adapted after the DMFMod-surfacing exec")

        -- io_dofile now delegates to real file.dofile (mod-root), not the
        -- WRONG method the chunk installed.
        local inst = setmetatable({}, { __index = sb.DMFMod })
        runner.assert_eq("delegated-value", inst:io_dofile("delegated"),
            "io_dofile delegates to real file.dofile (mod-root), not the WRONG original")

        -- io_dofile_unsafe delegates to real file.dofile_unsafe (which raises
        -- on a runtime error in the delegated chunk); the WRONG method is NOT
        -- called.
        local ok, err = pcall(function() inst:io_dofile_unsafe("throws") end)
        runner.assert_eq(false, ok, "io_dofile_unsafe delegates to the real unsafe op (which raises)")
        runner.assert_truthy(tostring(err):find("chunk%-throws") ~= nil,
            "the delegated chunk's error surfaces (not DMFMod's WRONG_UNSAFE)")
    end)

    -- -----------------------------------------------------------------
    -- Persisted developer-mode settings restoration (establish startup-only)
    -- -----------------------------------------------------------------
    --
    -- establish() must restore Managers.mod._settings from
    -- Application.user_setting("mod_manager_settings"): defensively pcall'd,
    -- identity + unrelated fields preserved, developer_mode required boolean
    -- (corrected to false in place). Falls back to { developer_mode = false }
    -- when Application is absent/throwing or the result is non-table. Re-call
    -- preserves the existing _settings identity (reload never re-restores).

    -- Build a fake Application whose user_setting(key) returns `value` (or
    -- throws/returns nil per opts).
    local function fake_application(value, opts)
        opts = opts or {}
        return {
            user_setting = function(key)
                if key ~= "mod_manager_settings" then return nil end
                if opts.throw then error("user_setting boom") end
                if opts.absent then return nil end
                return value
            end,
        }
    end

    runner.register("dmf_adapter: establish restores persisted settings table by identity (developer_mode true)", function()
        local persisted = { developer_mode = true }
        local sb, M = setup({ managers = {} })
        sb.Application = fake_application(persisted)
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        runner.assert_eq(persisted, manager._settings,
            "establish must reuse the persisted table identity")
        runner.assert_eq(true, manager._settings.developer_mode)
    end)

    runner.register("dmf_adapter: establish preserves unrelated persisted fields", function()
        local persisted = { developer_mode = true, log_level = 3, custom = { x = 1 } }
        local sb, M = setup()
        sb.Application = fake_application(persisted)
        local manager = fake_manager()
        M.new(manager):establish()
        runner.assert_eq(3, manager._settings.log_level, "unrelated field retained")
        runner.assert_eq(1, manager._settings.custom.x, "nested unrelated field retained")
        runner.assert_eq(true, manager._settings.developer_mode)
    end)

    runner.register("dmf_adapter: establish corrects missing developer_mode to false (identity preserved)", function()
        local persisted = { log_level = 2 }  -- no developer_mode field
        local sb, M = setup()
        sb.Application = fake_application(persisted)
        local manager = fake_manager()
        M.new(manager):establish()
        runner.assert_eq(persisted, manager._settings,
            "the same persisted table identity is kept")
        runner.assert_eq(false, manager._settings.developer_mode,
            "missing developer_mode corrected to false in place")
        runner.assert_eq(2, manager._settings.log_level, "unrelated field retained")
    end)

    runner.register("dmf_adapter: establish corrects non-boolean developer_mode to false", function()
        local persisted = { developer_mode = "yes" }
        local sb, M = setup()
        sb.Application = fake_application(persisted)
        local manager = fake_manager()
        M.new(manager):establish()
        runner.assert_eq(persisted, manager._settings, "identity preserved")
        runner.assert_eq(false, manager._settings.developer_mode,
            "non-boolean developer_mode corrected to false in place")
    end)

    runner.register("dmf_adapter: establish falls back to {developer_mode=false} when Application absent", function()
        local sb, M = setup()  -- no sb.Application
        local manager = fake_manager()
        M.new(manager):establish()
        runner.assert_type("table", manager._settings)
        runner.assert_eq(false, manager._settings.developer_mode)
    end)

    runner.register("dmf_adapter: establish falls back when Application.user_setting is not a function", function()
        local sb, M = setup()
        sb.Application = { user_setting = "not a function" }
        local manager = fake_manager()
        M.new(manager):establish()
        runner.assert_eq(false, manager._settings.developer_mode)
    end)

    runner.register("dmf_adapter: establish falls back when user_setting throws", function()
        local sb, M = setup()
        sb.Application = fake_application(nil, { throw = true })
        local manager = fake_manager()
        local ok = pcall(function()
            M.new(manager):establish()
        end)
        runner.assert_eq(true, ok, "establish must not propagate user_setting's error")
        runner.assert_eq(false, manager._settings.developer_mode)
    end)

    runner.register("dmf_adapter: establish falls back when the persisted result is non-table", function()
        local sb, M = setup()
        sb.Application = fake_application("not-a-table")
        local manager = fake_manager()
        M.new(manager):establish()
        runner.assert_eq(false, manager._settings.developer_mode)
    end)

    runner.register("dmf_adapter: establish preserves the existing _settings identity on re-call (startup-only)", function()
        -- establish() is called once at startup in production. On a defensive
        -- re-call it must NOT replace _settings (reload preserves the same
        -- table identity). It still resets _state/_mod_load_index to nil.
        local persisted = { developer_mode = true, extra = 7 }
        local sb, M = setup()
        sb.Application = fake_application(persisted)
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        local first = manager._settings
        -- Mutate state/index as if mid-load, then re-establish.
        manager._state = "intermediate"
        manager._mod_load_index = 3
        adapter:establish()
        runner.assert_eq(first, manager._settings,
            "re-establish must preserve the same _settings table identity")
        runner.assert_eq(true, manager._settings.developer_mode,
            "developer_mode not re-defaulted on re-establish")
        runner.assert_eq(7, manager._settings.extra, "unrelated field still present")
        runner.assert_nil(manager._state, "re-establish resets _state to nil")
        runner.assert_nil(manager._mod_load_index, "re-establish resets _mod_load_index to nil")
    end)

    runner.register("dmf_adapter: establish does not call Application.set_user_setting", function()
        -- The adapter must never persist; official DMF owns persistence.
        local sb, M = setup()
        local set_called = false
        sb.Application = {
            user_setting = function() return { developer_mode = false } end,
            set_user_setting = function() set_called = true end,
        }
        M.new(fake_manager()):establish()
        runner.assert_eq(false, set_called, "establish must not call set_user_setting")
    end)

    -- -----------------------------------------------------------------
    -- Reload transition / state-read methods
    -- -----------------------------------------------------------------

    runner.register("dmf_adapter: mark_load_pending resets _state to nil", function()
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        adapter:mark_load_done()
        runner.assert_eq("done", manager._state)
        adapter:mark_load_pending()
        runner.assert_nil(manager._state, "mark_load_pending resets _state (nil-before-done)")
    end)

    runner.register("dmf_adapter: is_load_done reports _state=='done' only", function()
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()
        runner.assert_eq(false, adapter:is_load_done(), "nil state -> not done")
        adapter:mark_load_done()
        runner.assert_eq(true, adapter:is_load_done())
        adapter:mark_load_pending()
        runner.assert_eq(false, adapter:is_load_done(), "pending -> not done")
    end)

    runner.register("dmf_adapter: developer_mode_enabled reports _settings.developer_mode==true", function()
        local sb, M = setup()
        local manager = fake_manager()
        local adapter = M.new(manager)
        adapter:establish()  -- no Application -> developer_mode false
        runner.assert_eq(false, adapter:developer_mode_enabled())
        manager._settings.developer_mode = true
        runner.assert_eq(true, adapter:developer_mode_enabled())
        manager._settings.developer_mode = "truthy-but-not-boolean"
        runner.assert_eq(false, adapter:developer_mode_enabled(),
            "only literal true counts (defensive against non-boolean)")
    end)

    -- -----------------------------------------------------------------
    -- retire_stale_generation_globals
    -- -----------------------------------------------------------------

    runner.register("dmf_adapter: retire clears _G.DMFMod/new_mod/get_mod", function()
        local sb, M = setup()
        local adapter = M.new(fake_manager())
        sb.DMFMod = { io_dofile = function() end }
        sb.new_mod = function() end
        sb.get_mod = function() end
        -- An unrelated Relay/global surface that must survive.
        sb.CLASS = sb.CLASS or {}
        sb.Managers = sb.Managers or {}
        sb.Managers.dmf = { persistent_tables = {} }
        adapter:retire_stale_generation_globals()
        runner.assert_nil(sb.DMFMod, "DMFMod retired")
        runner.assert_nil(sb.new_mod, "new_mod retired")
        runner.assert_nil(sb.get_mod, "get_mod retired")
    end)

    runner.register("dmf_adapter: retire does NOT clear CLASS / Managers.dmf / persistent_tables", function()
        local sb, M = setup()
        local adapter = M.new(fake_manager())
        local class_tbl = {}
        sb.CLASS = class_tbl
        local dmf_tbl = { persistent_tables = { mods = {} } }
        sb.Managers = { dmf = dmf_tbl }
        adapter:retire_stale_generation_globals()
        runner.assert_eq(class_tbl, sb.CLASS, "CLASS survives retirement")
        runner.assert_eq(dmf_tbl, sb.Managers.dmf, "Managers.dmf survives")
        runner.assert_eq(dmf_tbl.persistent_tables, sb.Managers.dmf.persistent_tables,
            "persistent_tables survive")
    end)

    runner.register("dmf_adapter: retire RETAINS the table+wrapper markers (not reset)", function()
        -- The table+wrapper comparison in adapt_dmf_io is load-bearing for
        -- correctness. Retaining the markers across retire keeps a reused-table
        -- re-exposure before core/io a clean no-op (the table still carries
        -- Relay's wrappers from the prior generation), avoids spurious
        -- re-adaptation, and preserves accurate installation state. The later
        -- core/io method-overwrite trips the wrapper mismatch and is what
        -- guarantees re-adaptation + correctness.
        local sb, M, observers = setup({ with_observer_list = true })
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.DMFMod = full_dmfmod_surface()
        sb.Mods.file.notify()
        runner.assert_eq(sb.DMFMod, adapter:adapted_dmfmod(), "gen1 adapted")
        local gen1 = sb.DMFMod
        local gen1_wrapper = adapter:adapted_io_dofile()
        runner.assert_eq(gen1.io_dofile, gen1_wrapper, "marker is the installed wrapper")

        -- Retire clears the globals but RETAINS both private markers.
        adapter:retire_stale_generation_globals()
        runner.assert_nil(sb.DMFMod, "global cleared")
        runner.assert_eq(gen1, adapter:adapted_dmfmod(),
            "retire RETAINS the adapted table marker (not forgotten)")
        runner.assert_eq(gen1_wrapper, adapter:adapted_io_dofile(),
            "retire RETAINS the wrapper marker (not forgotten)")

        -- Re-expose the SAME class table (class() reused it). It still carries
        -- Relay's wrappers from gen1, so the observer fire must NO-OP — no
        -- premature re-adaptation.
        sb.DMFMod = gen1
        sb.Mods.file.notify()
        runner.assert_eq(gen1_wrapper, sb.DMFMod.io_dofile,
            "re-exposed same table keeps Relay's wrapper (no premature change)")
        runner.assert_eq(gen1, adapter:adapted_dmfmod(), "table marker unchanged")
        runner.assert_eq(gen1_wrapper, adapter:adapted_io_dofile(),
            "wrapper marker unchanged")

        -- Now core/io.lua overwrites io_dofile on that SAME table with a stock
        -- method. The wrapper mismatch must trigger a full re-adaptation.
        gen1.io_dofile = function() return "STOCK" end
        sb.Mods.file.notify()
        runner.assert_eq(gen1, adapter:adapted_dmfmod(), "same table still tracked")
        runner.assert_truthy(gen1_wrapper ~= adapter:adapted_io_dofile(),
            "wrapper marker advanced after core/io overwrite")
        runner.assert_truthy(gen1.io_dofile ~= gen1_wrapper,
            "io_dofile is no longer the old wrapper")
        runner.assert_eq(gen1.io_dofile, adapter:adapted_io_dofile(),
            "io_dofile is now the freshly-installed Relay wrapper")
    end)

    runner.register("dmf_adapter: retire-then-NEW-table still adapts fresh", function()
        -- A genuinely new DMFMod table (class() did NOT reuse) adapts normally
        -- after retire: the retained markers are for a DIFFERENT table, so the
        -- table mismatch drives adaptation once io_dofile is a function.
        local sb, M, observers = setup({ with_observer_list = true })
        local adapter = M.new(fake_manager())
        adapter:register_io_observer()
        sb.DMFMod = full_dmfmod_surface()
        sb.Mods.file.notify()
        local gen1 = sb.DMFMod
        adapter:retire_stale_generation_globals()
        runner.assert_eq(gen1, adapter:adapted_dmfmod(), "marker retained")
        sb.DMFMod = full_dmfmod_surface()
        runner.assert_truthy(gen1 ~= sb.DMFMod, "sanity: gen2 is a distinct table")
        sb.Mods.file.notify()
        runner.assert_eq(sb.DMFMod, adapter:adapted_dmfmod(),
            "the new (distinct) table is adapted after retire")
        runner.assert_eq(sb.DMFMod.io_dofile, adapter:adapted_io_dofile(),
            "wrapper marker advanced to the new table's wrapper")
    end)

    runner.register("dmf_adapter: retire is safe when the globals are already nil", function()
        local sb, M = setup()
        local adapter = M.new(fake_manager())
        local ok, err = pcall(function() adapter:retire_stale_generation_globals() end)
        runner.assert_eq(true, ok, "retire must not raise when globals already nil: " .. tostring(err))
    end)

    -- ---------------------------------------------------------------------
    -- Same-table reuse regression through the REAL file.lua observer.
    -- Faithfully reproduces the live failure timing: class("DMFMod") reuses the
    -- table; dmf_mod_data.lua re-exposes it before core/io.lua overwrites the
    -- methods. The observer must no-op on re-exposure and re-adapt after the
    -- overwrite so a NumericUI-like path routes through Mods.file, not ./../mods.
    -- ---------------------------------------------------------------------

    runner.register("dmf_adapter: same-table DMF generation re-adapts after core/io overwrite (real observer)", function()
        local sb = mock.new_sandbox()
        sb.__print = function() end
        sb.Managers = {}
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT }
        -- class_registry owns the _G[class_name] retire surface (production
        -- loads it before dmf_adapter). Seed the contract so retire routes
        -- DMFMod through Mods.retire_class.
        sb.Mods.retire_class = function(name)
            if type(name) == "string" then sb[name] = nil end
        end
        local files = {}
        -- An unrelated chunk used solely to fire the real observer.
        files[mock.MOD_ROOT .. "/spark.lua"] = "return 'spark'"
        -- A NumericUI-like mod script the adapted io_dofile must resolve from
        -- the mod root (not ./../mods).
        files[mock.MOD_ROOT .. "/NumericUI/file.lua"] = "return 'relay-root-resolved'"
        sb.Mods.lua.io = mock.make_io(files)
        sb.Mods.lua.loadstring = sb.loadstring
        sb.Mods.load_module = function(name) return mock.run_module(name, sb) end

        mock.run_module("file", sb)
        -- Wrap add_observer with a counter so the test can assert the adapter
        -- registers exactly one observer across the whole sequence.
        local add_calls = 0
        local real_add = sb.Mods.file.add_observer
        sb.Mods.file.add_observer = function(fn)
            add_calls = add_calls + 1
            real_add(fn)
        end

        local M = mock.run_module("dmf_adapter", sb)
        local adapter = M.new(fake_manager())
        adapter:establish()
        adapter:register_io_observer()
        runner.assert_eq(1, add_calls, "exactly one observer registered")

        -- Stock ./../mods surface installer (what core/io.lua does). Returns a
        -- wrong-root path string so we can detect if it is ever called.
        local function install_stock_surface(tbl)
            tbl.io_dofile = function(self, p) return "STOCK:" .. "./../mods/" .. p end
            tbl.io_dofile_unsafe = function(self, p) return "STOCK_UNSAFE:" .. p end
            tbl.io_exec = function(self, lp, fn, ext, args) return "STOCK_EXEC" end
            tbl.io_exec_unsafe = function(self, lp, fn, ext, args) return "STOCK_EXEC_U" end
            tbl.io_exec_with_return = function(self, lp, fn, ext, args) return "STOCK_EXEC_R" end
            tbl.io_exec_unsafe_with_return = function(self, lp, fn, ext, args) return "STOCK_EXEC_UR" end
            tbl.io_read_content = function(self, p, ext) return "STOCK_RC" end
            tbl.io_read_content_to_table = function(self, p, ext) return "STOCK_RCT" end
        end

        -- Generation 1: class("DMFMod") -> table T; core/io installs stock;
        -- observer fires and adapts T (eight methods -> Mods.file.*).
        local T = {}
        sb.DMFMod = T
        install_stock_surface(T)
        sb.Mods.file.dofile("spark")  -- fires the real observer -> adapt gen1
        runner.assert_eq(T, adapter:adapted_dmfmod(), "gen1 adapted")
        local gen1_wrapper = adapter:adapted_io_dofile()
        runner.assert_truthy(gen1_wrapper ~= T.io_dofile or T.io_dofile == gen1_wrapper,
            "sanity: gen1 io_dofile is the Relay wrapper")
        runner.assert_eq(T.io_dofile, gen1_wrapper, "marker == installed wrapper")

        -- --- Reload teardown ---
        adapter:retire_stale_generation_globals()
        runner.assert_nil(sb.DMFMod, "global retired")
        runner.assert_eq(T, adapter:adapted_dmfmod(),
            "marker RETAINED across retire (key to the fix)")
        runner.assert_eq(gen1_wrapper, adapter:adapted_io_dofile(),
            "wrapper marker RETAINED across retire")

        -- dmf_mod_data.lua re-exposes the SAME class table (class() reused it),
        -- BEFORE core/io.lua runs. T still carries Relay's wrappers. Observer
        -- fire must NO-OP (table + wrapper both still match).
        sb.DMFMod = T
        sb.Mods.file.dofile("spark")  -- represents dmf_mod_data.lua exec
        runner.assert_eq(gen1_wrapper, T.io_dofile,
            "no premature re-adaptation; Relay wrapper remains on re-exposure")
        runner.assert_eq(T, adapter:adapted_dmfmod(), "table marker unchanged")
        runner.assert_eq(gen1_wrapper, adapter:adapted_io_dofile(),
            "wrapper marker unchanged after re-exposure fire")

        -- core/io.lua overwrites ALL EIGHT methods on the SAME table with stock.
        install_stock_surface(T)
        runner.assert_truthy(T.io_dofile ~= gen1_wrapper,
            "sanity: core/io replaced io_dofile with stock")

        -- Observer fire after core/io: wrapper mismatch -> full re-adaptation.
        sb.Mods.file.dofile("spark")
        runner.assert_eq(T, adapter:adapted_dmfmod(), "same table still tracked")
        runner.assert_truthy(gen1_wrapper ~= adapter:adapted_io_dofile(),
            "wrapper marker advanced after core/io overwrite")
        runner.assert_eq(T.io_dofile, adapter:adapted_io_dofile(),
            "io_dofile is the freshly-installed Relay wrapper")

        -- A NumericUI-like path now routes through Mods.file (mod root), NOT
        -- the stock ./../mods method.
        local inst = setmetatable({}, { __index = T })
        local result = inst:io_dofile("NumericUI/file")
        runner.assert_eq("relay-root-resolved", result,
            "io_dofile routes through Mods.file (mod root), not STOCK ./../mods")

        -- All eight methods were re-adapted (none left as STOCK). Verify a
        -- representative exec + read_content route through Mods.file too.
        runner.assert_truthy(inst:io_exec("NumericUI", "file", "lua") ~= "STOCK_EXEC",
            "io_exec re-adapted (not stock)")
        runner.assert_truthy(inst:io_read_content("NumericUI/file") ~= "STOCK_RC",
            "io_read_content re-adapted (not stock)")
        runner.assert_truthy(inst:io_read_content_to_table("NumericUI/file") ~= "STOCK_RCT",
            "io_read_content_to_table re-adapted (not stock)")

        -- Same-generation unrelated observer fires remain idempotent.
        local wrapper_after = T.io_dofile
        sb.Mods.file.dofile("spark")
        sb.Mods.file.dofile("spark")
        runner.assert_eq(wrapper_after, T.io_dofile,
            "same-generation re-fire is idempotent (no re-adapt)")

        -- Observer count stays one: retire/reload never re-registers, and
        -- re-calling register_io_observer is a no-op.
        adapter:register_io_observer()
        adapter:register_io_observer()
        runner.assert_eq(1, add_calls,
            "observer count stays one across retire + reuse + re-adapt")
    end)
end
