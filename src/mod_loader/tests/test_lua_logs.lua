-- test_lua_logs.lua — the optional lua-log tee installed by init.lua.
--
-- Covers the Lua side of the RELAY_LUA_LOGS=1 print tee: the temporary
-- __mod_relay_lua_log_sink global is consumed + retired before any later
-- bootstrap behavior, then global print + __print are wrapped best-effort so
-- every SUCCESSFUL print also reaches the private sink (originals stay
-- authoritative: called first, errors propagated, returns preserved, capture
-- failures swallowed). Uses Relay-owned fakes only (no real engine, no wine).
--
-- Harness note: the entry chunk's env is the sandbox (mock.load_module does
-- setfenv), so a temp global set on the sandbox (sb.__mod_relay_lua_log_sink)
-- is exactly what the C trampoline would publish on the real VM. The loader
-- also calls its own wrapped __print for the trailing "loaded at pcall#1"
-- line, so each test clears the shared spy lists once after init before making
-- its own assertions about per-call behavior.

local mock = require("mock")

-- Append-only list clear (no table.clear in Lua 5.1). The spy lists never have
-- holes, so a sequential nil-out resets #t to 0.
local function clear(t)
    for i = 1, #t do t[i] = nil end
end

-- Call fn(...) and collect {n = count, [1..n] = values}. Uses select("#") + a
-- grab forwarder so nil positions survive (the count is authoritative; a missing
-- index in [1..n] is a nil). Mirror of the tee's own result-preservation logic.
local function collect(fn, ...)
    local out = {}
    local function grab(...)
        out.n = select("#", ...)
        for i = 1, out.n do out[i] = select(i, ...) end
    end
    grab(fn(...))
    return out
end

return function(runner)
    -- A fresh sandbox with the loader root staged + a no-op pre-wrap require.
    -- Tests add their own print / __print / __mod_relay_lua_log_sink before
    -- running the entry.
    local function fresh_sb()
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.MOD_RELAY_VERSION = "test"
        sb.require = function() return {} end
        sb.io = mock.make_io(mock.stage_mod_loader())
        return sb
    end

    -- A recording print surface: each call's arg count + values are appended to
    -- `log`; returns the literal values in `returns` (default: nothing).
    local function recorder(log, returns)
        return function(...)
            local rec = { n = select("#", ...) }
            for i = 1, rec.n do rec[i] = select(i, ...) end
            log[#log + 1] = rec
            if returns then return unpack(returns) end
        end
    end

    -- A recording sink: appends each rendered string it receives.
    local function sink_recorder(log)
        return function(s) log[#log + 1] = s end
    end

    -- A recording print that also mirrors real print's tostring-per-arg, used to
    -- prove capture does not re-invoke a user __tostring metamethod.
    local function tostring_recorder(log, metamethod_log)
        return function(...)
            local rec = { n = select("#", ...) }
            for i = 1, rec.n do rec[i] = select(i, ...) end
            log[#log + 1] = rec
            for i = 1, rec.n do
                local v = select(i, ...)
                if type(v) == "table" and getmetatable(v) then
                    -- tostring on a table with __tostring invokes it once
                    metamethod_log[#metamethod_log + 1] = tostring(v)
                end
            end
        end
    end

    -- ------------------------------------------------------------------
    -- Bootstrap + retirement
    -- ------------------------------------------------------------------

    runner.register("lua-logs: no sink — print identity unchanged; __print = __print or print", function()
        local sb = fresh_sb()
        local orig_print = function() end
        sb.print = orig_print
        -- __print deliberately unset (nil) — must fall back to print.
        mock.load_module("init", sb)()
        runner.assert_eq(orig_print, sb.print, "print unchanged when no sink published")
        runner.assert_eq(orig_print, sb.__print, "__print falls back to print (current behavior preserved)")
        runner.assert_nil(sb.__mod_relay_lua_log_sink, "temp global is nil (never set)")
        runner.assert_nil(sb.Mods._relay._print_tee_installed, "no wrap marker set with no sink")
    end)

    runner.register("lua-logs: valid sink — temp global retired; original then sink, once each", function()
        local sb = fresh_sb()
        local order, print_log, sink_log = {}, {}, {}
        sb.print = function(...)
            order[#order + 1] = "print"
            print_log[#print_log + 1] = { n = select("#", ...) }
            for i = 1, select("#", ...) do print_log[#print_log][i] = select(i, ...) end
        end
        sb.__mod_relay_lua_log_sink = function(s)
            order[#order + 1] = "sink"
            sink_log[#sink_log + 1] = s
        end
        mock.load_module("init", sb)()
        -- Retired before any later bootstrap behavior; the wrapper still works
        -- (it holds the sink privately), proving retirement is safe.
        runner.assert_nil(sb.__mod_relay_lua_log_sink, "temp global retired before subsequent bootstrap")
        runner.assert_truthy(sb.Mods._relay._print_tee_installed, "wrap marker set")
        -- Clear the loader's own trailing "loaded at pcall#1" tee'd call.
        clear(order); clear(print_log); clear(sink_log)

        sb.print("hello")
        runner.assert_eq(1, #print_log, "original print called exactly once")
        runner.assert_eq(1, #sink_log, "sink called exactly once")
        runner.assert_eq("print", order[1], "original print called first")
        runner.assert_eq("sink", order[2], "sink called after original")
        runner.assert_eq("hello", sink_log[1], "sink received the rendered string")
    end)

    runner.register("lua-logs: invalid (non-function) sink retired; no wrapper installed", function()
        for _, bad in ipairs({ "not a function", 42, {}, true }) do
            local sb = fresh_sb()
            local orig_print = function() end
            sb.print = orig_print
            sb.__mod_relay_lua_log_sink = bad
            local ok = mock.load_module("init", sb)()
            runner.assert_eq(true, ok, "entry still succeeds with an invalid sink (" .. tostring(bad) .. ")")
            runner.assert_nil(sb.__mod_relay_lua_log_sink, "invalid sink retired (" .. tostring(bad) .. ")")
            runner.assert_eq(orig_print, sb.print, "no wrapper installed for invalid sink (" .. tostring(bad) .. ")")
            runner.assert_nil(sb.Mods._relay._print_tee_installed, "no wrap marker for invalid sink")
        end
    end)

    -- ------------------------------------------------------------------
    -- Aliased vs distinct originals
    -- ------------------------------------------------------------------

    runner.register("lua-logs: aliased print/__print share ONE wrapper (no nested/double capture)", function()
        local sb = fresh_sb()
        local calls, sink_log = 0, {}
        local shared_orig = function(...) calls = calls + 1 end
        sb.print = shared_orig
        sb.__print = shared_orig  -- aliased to the SAME function
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        runner.assert_eq(sb.print, sb.__print, "print and __print are the SAME wrapper object")
        runner.assert_truthy(sb.print ~= shared_orig, "the global was actually wrapped")
        clear(sink_log); calls = 0

        sb.print("a")
        runner.assert_eq(1, calls, "shared original called once via print")
        runner.assert_eq(1, #sink_log, "sink called once (no double capture)")
        calls = 0; clear(sink_log)

        sb.__print("b")
        runner.assert_eq(1, calls, "shared original called once via __print")
        runner.assert_eq(1, #sink_log, "sink called once via __print (no nested capture)")
    end)

    runner.register("lua-logs: distinct originals stay distinct; each calls its own original", function()
        local sb = fresh_sb()
        local print_log, dunder_log, sink_log = {}, {}, {}
        local orig_print = recorder(print_log)
        local orig_dunder = recorder(dunder_log)
        sb.print = orig_print
        sb.__print = orig_dunder  -- distinct from print
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        runner.assert_truthy(sb.print ~= sb.__print, "distinct originals yield distinct wrappers (not collapsed)")
        runner.assert_truthy(sb.print ~= orig_print, "print wrapped")
        runner.assert_truthy(sb.__print ~= orig_dunder, "__print wrapped")
        clear(print_log); clear(dunder_log); clear(sink_log)

        sb.print("via-print")
        runner.assert_eq(1, #print_log, "print's wrapper called print's original")
        runner.assert_eq(0, #dunder_log, "print's wrapper did NOT call __print's original")
        runner.assert_eq("via-print", sink_log[1], "sink captured the print call")
        clear(print_log); clear(dunder_log); clear(sink_log)

        sb.__print("via-dunder")
        runner.assert_eq(1, #dunder_log, "__print's wrapper called __print's original")
        runner.assert_eq(0, #print_log, "__print's wrapper did NOT call print's original")
        runner.assert_eq("via-dunder", sink_log[1], "sink captured the __print call")
    end)

    runner.register("lua-logs: __print absent (nil) — shared wrapper via the __print or print fallback", function()
        -- __print unset -> __print = __print or print resolves to print -> same
        -- surface -> one shared wrapper on both globals (the common engine case
        -- where DMF has not yet aliased print under __print).
        local sb = fresh_sb()
        local print_log, sink_log = {}, {}
        sb.print = recorder(print_log)
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        runner.assert_eq(sb.print, sb.__print, "shared wrapper (nil __print fell back to print)")
        clear(print_log); clear(sink_log)
        sb.__print("x")
        runner.assert_eq(1, #print_log, "fallback __print routed through the print original")
        runner.assert_eq("x", sink_log[1], "sink captured")
    end)

    -- ------------------------------------------------------------------
    -- Renderer
    -- ------------------------------------------------------------------

    runner.register("lua-logs: one string + multiple primitive/nil args render tab-delimited", function()
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(sink_log)
        -- trailing nil arg IS counted by select("#"); renders as "nil".
        sb.print("one", 2, true, nil)
        runner.assert_eq(1, #sink_log, "one sink call")
        runner.assert_eq("one\t2\ttrue\tnil", sink_log[1], "primitives + nil tab-joined (trailing nil preserved)")
        clear(sink_log)
        sb.print()
        runner.assert_eq("", sink_log[1], "empty arg list renders as the empty string")
    end)

    runner.register("lua-logs: number rendering uses ordinary textual forms", function()
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(sink_log)
        sb.print(0, -1, 3.5, 1000000)
        runner.assert_eq("0\t-1\t3.5\t1000000", sink_log[1], "numbers use tostring's ordinary forms")
    end)

    runner.register("lua-logs: complex values render as placeholders; __tostring not invoked by capture", function()
        local sb = fresh_sb()
        local sink_log, meta_log, print_log = {}, {}, {}
        local mt_calls = 0
        local tab = setmetatable({}, { __tostring = function() mt_calls = mt_calls + 1; return "FROM_META" end })
        -- Original mirrors real print: tostring-per-arg (invokes __tostring once
        -- for the table). Capture must NOT invoke it a second time.
        sb.print = tostring_recorder(print_log, meta_log)
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(sink_log); clear(meta_log); clear(print_log); mt_calls = 0

        local co = coroutine.create(function() end)
        sb.print(tab, function() end, co)
        runner.assert_eq(1, #sink_log, "one sink call")
        runner.assert_eq("<table>\t<function>\t<thread>", sink_log[1],
            "complex values render as stable type placeholders, tab-joined")
        runner.assert_eq(1, mt_calls,
            "__tostring invoked exactly once (by the original), never by capture")
    end)

    runner.register("lua-logs: LuaJIT cdata renders as <cdata> (distinct from userdata)", function()
        -- LuaJIT 2.1: type(ffi.new(...)) == "cdata" (NOT "userdata"). The
        -- renderer has a dedicated cdata branch, so an FFI value gets the stable
        -- <cdata> placeholder and is never re-converted. Grounded against the
        -- installed LuaJIT (2.1.1784580905); require("ffi") comes from the test
        -- environment, not exposed as a new public interface.
        local ffi = require("ffi")
        runner.assert_eq("cdata", type(ffi.new("int[1]")),
            "test precondition: LuaJIT reports cdata for ffi.new")

        local sb = fresh_sb()
        local print_log, sink_log = {}, {}
        local calls = 0
        sb.print = function(...)
            calls = calls + 1
            local rec = { n = select("#", ...) }
            for i = 1, rec.n do rec[i] = select(i, ...) end
            print_log[#print_log + 1] = rec
        end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(print_log); clear(sink_log); calls = 0

        local cdata_val = ffi.new("int[1]")
        cdata_val[0] = 42
        sb.print("prefix", cdata_val, "suffix")

        runner.assert_eq(1, calls, "original fake is authoritative and called exactly once")
        runner.assert_eq(3, print_log[1].n, "all three args reached the original (cdata included)")
        runner.assert_eq("prefix\t<cdata>\tsuffix", sink_log[1],
            "cdata renders as the stable <cdata> placeholder, not <userdata>")
    end)

    runner.register("lua-logs: string passed through byte-for-byte", function()
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(sink_log)
        sb.print("with %s and \t a real percent-percent %%")
        runner.assert_eq("with %s and \t a real percent-percent %%", sink_log[1],
            "string bytes (incl. % and tab) passed through unchanged — native owns escaping")
    end)

    runner.register("lua-logs: multiline string handed to the sink intact", function()
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(sink_log)
        local ml = "line1\nline2\r\nline3\n"
        sb.print(ml)
        runner.assert_eq(ml, sink_log[1],
            "multiline string handed to the sink byte-for-byte (native owns CR/LF splitting)")
    end)

    -- ------------------------------------------------------------------
    -- Authoritative original behavior
    -- ------------------------------------------------------------------

    runner.register("lua-logs: original error propagates; sink not called", function()
        local sb = fresh_sb()
        local sink_log = {}
        local triggered = false
        -- Original errors only on a sentinel, so the loader's own diagnostic
        -- prints still succeed during bootstrap.
        sb.print = function(msg, ...)
            if msg == "__boom__" then error("print exploded", 0) end
        end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(sink_log)

        local ok, err = pcall(sb.print, "__boom__")
        runner.assert_eq(false, ok, "original error propagated through the wrapper")
        runner.assert_eq("print exploded", err, "the original error value is preserved")
        runner.assert_eq(0, #sink_log, "sink NOT called when the original errored")
    end)

    runner.register("lua-logs: original error provenance preserved (natural propagation, not a rethrow)", function()
        -- A pcall+rethrow design unwinds the original's frame BEFORE the outer
        -- handler runs; a DIRECT original(...) call keeps it on the stack. We
        -- distinguish the two at the FRAME level (debug.getinfo source walk),
        -- NOT via the error message string: the message carries the source:line
        -- prefix in both designs (it's baked in by the original's error() call
        -- before any pcall boundary), so a message check would pass either way.
        -- Only a present frame proves natural propagation.
        local sb = fresh_sb()
        local sink_log = {}
        -- Original in its own chunk with a distinctive source name, so its frame
        -- is identifiable in an outer xpcall handler's stack walk.
        local original = loadstring(
            "return function(msg)\n" ..
            "  if msg == '__boom__' then error('provenance boom') end\n" ..
            "end\n",
            "PROVENANCE_ORIGIN")()
        sb.print = original
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(sink_log)

        local origin_frame_seen, err_captured
        local function handler(err)
            err_captured = err
            -- Walk every frame's source from inside the handler. The original's
            -- frame is on the stack here ONLY under direct propagation.
            local level, found = 1, false
            while true do
                local info = debug.getinfo(level, "S")
                if not info then break end
                if info.source and string.find(info.source, "PROVENANCE_ORIGIN", 1, true) then
                    found = true
                    break
                end
                level = level + 1
            end
            origin_frame_seen = found
            return err
        end
        local ok = xpcall(sb.print, handler, "__boom__")
        runner.assert_eq(false, ok, "the original error propagated through the wrapper")
        runner.assert_truthy(string.find(tostring(err_captured), "provenance boom", 1, true),
            "the original error message survived")
        runner.assert_truthy(origin_frame_seen,
            "original's frame present at the outer handler (natural propagation); " ..
            "a pcall+rethrow would have unwound it before the handler ran")
        runner.assert_eq(0, #sink_log, "sink NOT called when the original errored")
    end)

    runner.register("lua-logs: zero / multiple return values (incl. nil cardinality) preserved", function()
        local sb = fresh_sb()
        local sink_log = {}
        -- Distinct originals returning specific value shapes.
        sb.print = function() return end                      -- zero results
        sb.__print = function() return "a", nil, "c" end      -- 3 results, middle nil
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(sink_log)

        -- print: zero results.
        local r = collect(sb.print, "x")
        runner.assert_eq(0, r.n, "zero-result original stays zero-result through the wrapper")
        runner.assert_eq(1, #sink_log, "sink still captured the call")

        -- __print: 3 results with a middle nil preserved.
        local r2 = collect(sb.__print, "y")
        runner.assert_eq(3, r2.n, "result count preserved (3)")
        runner.assert_eq("a", r2[1], "result[1] preserved")
        runner.assert_nil(r2[2], "interior nil result preserved (by position)")
        runner.assert_eq("c", r2[3], "result[3] preserved")

        -- Leading-nil result original.
        local sb2 = fresh_sb()
        sb2.print = function() return nil, "x" end            -- 2 results, leading nil
        sb2.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb2)()
        local r3 = collect(sb2.print, "z")
        runner.assert_eq(2, r3.n, "leading-nil result count preserved (2)")
        runner.assert_nil(r3[1], "leading nil result preserved")
        runner.assert_eq("x", r3[2], "second result preserved")
    end)

    runner.register("lua-logs: sink error (after original success) swallowed; results preserved", function()
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() return "ok-1", "ok-2" end
        sb.__mod_relay_lua_log_sink = function(_s) error("sink exploded", 0) end
        mock.load_module("init", sb)()
        -- The loader's own trailing print already proved sink errors are silent.

        local r = collect(sb.print, "payload")
        runner.assert_eq(2, r.n, "original results still returned when the sink errors")
        runner.assert_eq("ok-1", r[1], "result[1] preserved")
        runner.assert_eq("ok-2", r[2], "result[2] preserved")
    end)

    runner.register("lua-logs: capture failure never changes successful application behavior", function()
        -- A sink that errors should be indistinguishable from a healthy sink to
        -- the caller of print: same results, original called once, no leak.
        local sb = fresh_sb()
        local calls = 0
        sb.print = function(...) calls = calls + 1; return "r" end
        sb.__mod_relay_lua_log_sink = function(_s) error("boom", 0) end
        mock.load_module("init", sb)()
        calls = 0
        local r = collect(sb.print, "x")
        runner.assert_eq(1, calls, "original called exactly once despite sink failure")
        runner.assert_eq(1, r.n, "single result returned")
        runner.assert_eq("r", r[1], "the original's result returned intact")
    end)

    -- ------------------------------------------------------------------
    -- Wrapper insulation (captured locals) + capture-failure containment
    -- ------------------------------------------------------------------

    runner.register("lua-logs: later global-helper replacement does not break the installed wrapper", function()
        -- The wrappers capture pcall/select/unpack/type/tostring/table.concat ONCE
        -- at install and close over them. Sabotaging those SANDBOX bindings
        -- afterward must not affect the wrapper: the original is still called,
        -- results still forwarded with nil cardinality, and rendering still
        -- correct. (The sandbox `table` binding is replaced wholesale — the
        -- shared host table is never mutated.)
        local sb = fresh_sb()
        local print_log, sink_log = {}, {}
        sb.print = recorder(print_log)
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(print_log); clear(sink_log)

        sb.pcall = function() error("sabotaged pcall") end
        sb.select = function() error("sabotaged select") end
        sb.unpack = function() error("sabotaged unpack") end
        sb.type = function() error("sabotaged type") end
        sb.tostring = function() error("sabotaged tostring") end
        -- A brand-new sandbox `table` binding (NOT a mutation of the shared host
        -- table) whose every access fails.
        sb.table = setmetatable({}, { __index = function(_, k) error("sabotaged table." .. tostring(k)) end })

        local r = collect(sb.print, "still", "works", nil)
        runner.assert_eq(1, #print_log, "original still called once despite helper sabotage")
        runner.assert_eq(3, print_log[1].n, "input arg count (incl trailing nil) still reaches the original")
        runner.assert_eq(1, #sink_log, "capture still ran despite helper sabotage")
        runner.assert_eq("still\tworks\tnil", sink_log[1],
            "renderer still correct (captured type/tostring/concat, not the sabotaged globals)")
        runner.assert_eq(0, r.n, "zero-result original still forwards zero through the wrapper")
    end)

    runner.register("lua-logs: renderer is total under local capture; sink is the sole fallible protected boundary", function()
        -- Under the local-capture design the renderer is TOTAL: it dispatches
        -- over every Lua type via the captured _type/_tostring/_concat and table
        -- constructors, so it has no failure mode on any well-typed value.
        -- Replacing the sandbox `table` binding (incl. concat) AFTER install
        -- cannot induce a renderer fault, because the wrapper holds the real
        -- table.concat privately — so there is no safe seam to inject a renderer
        -- failure without a production-only hook (sabotaging the real host
        -- table.concat would break the whole harness, not just the wrapper). The
        -- ONLY fallible boundary left inside the protected _pcall(_capture, ...)
        -- is the sink itself; its containment is exercised here and in the
        -- dedicated sink-error tests above.
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() return "orig" end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        clear(sink_log)

        -- (a) Sabotage the sandbox table binding wholesale (new table, broken
        --     concat). Rendering must be unaffected — the wrapper never looks up
        --     sb.table.concat; it uses the captured real concat. This is the
        --     "would only fail under dynamic lookup" case, shown inert.
        sb.table = setmetatable({}, {
            __index = function(_, k)
                if k == "concat" then return function() error("sabotaged concat") end end
                error("sabotaged table." .. tostring(k))
            end,
        })
        local r1 = collect(sb.print, "a", "b")
        runner.assert_eq(1, #sink_log, "render still produced a capture (renderer is insulated)")
        runner.assert_eq("a\tb", sink_log[1], "render output correct via the captured concat")
        runner.assert_eq(1, r1.n, "result count preserved")
        runner.assert_eq("orig", r1[1], "result value preserved")
        clear(sink_log)

        -- (b) The one protected fallible boundary: a FAILING sink is contained
        --     and the original's results still pass through (interior nil kept).
        local sb2 = fresh_sb()
        sb2.print = function() return "x", nil, "z" end
        sb2.__mod_relay_lua_log_sink = function(_s) error("sink failure", 0) end
        mock.load_module("init", sb2)()
        local r2 = collect(sb2.print, "payload")
        runner.assert_eq(3, r2.n, "result count preserved when the sink fails")
        runner.assert_eq("x", r2[1])
        runner.assert_nil(r2[2], "interior nil preserved when the sink fails")
        runner.assert_eq("z", r2[3])
    end)

    -- ------------------------------------------------------------------
    -- Idempotency + hot-reload invariance
    -- ------------------------------------------------------------------

    runner.register("lua-logs: repeated/partial entry cannot stack wrappers; temp global always retired", function()
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        runner.assert_eq(true, sb.Mods._loaded, "first entry loaded")
        local wrapper_after_first = sb.print
        clear(sink_log)

        -- Re-publish a fresh temp global (defensive — the trampoline is one-shot,
        -- but a partial/repeated entry must retire it regardless).
        sb.__mod_relay_lua_log_sink = function(s) sink_log[#sink_log + 1] = "second:" .. s end
        local r = mock.load_module("init", sb)()  -- _loaded guard bails early
        runner.assert_eq(true, r, "second entry returns cleanly")
        runner.assert_nil(sb.__mod_relay_lua_log_sink,
            "newly-presented temp global retired even on the early-return path")
        runner.assert_eq(wrapper_after_first, sb.print,
            "wrapper identity unchanged — no second wrapper stacked")

        -- A call through the (still-original, single) wrapper hits the FIRST sink
        -- captured at install time, exactly once. The second (un-retired-in-time
        -- by design) callback never wired up because no second wrap occurred.
        local n_before = #sink_log
        sb.print("post")
        runner.assert_eq(n_before + 1, #sink_log, "still exactly one sink invocation per print (no stacking)")
    end)

    runner.register("lua-logs: partial entry (aborted after wrap) does not re-wrap on re-entry", function()
        -- Simulate a partial first entry: install the tee, set the marker, but do
        -- NOT set _loaded (as if bootstrap aborted later). A re-entry must skip
        -- re-wrapping even though _loaded is false.
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        local wrapper_after_first = sb.print
        -- Forcibly clear _loaded to simulate the abort having happened after the
        -- wrap completed (the marker survives under Mods._relay).
        sb.Mods._loaded = nil

        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        runner.assert_eq(wrapper_after_first, sb.print,
            "marker prevents a second wrap even when _loaded was cleared (no stacking)")
        runner.assert_nil(sb.__mod_relay_lua_log_sink,
            "temp global still retired on the re-entry path")
    end)

    runner.register("lua-logs: wrapper survives simulated hot-reload state changes (not removed/reinstalled)", function()
        -- Hot reload reuses this Lua state but never re-runs the one-shot entry.
        -- Simulate reload-related state churn and confirm the wrappers are
        -- process-lifetime: identity stable, still functional, not reinstalled.
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        local wrapper_print, wrapper_dunder = sb.print, sb.__print
        runner.assert_truthy(sb.Mods._relay._print_tee_installed, "marker set at process start")
        clear(sink_log)

        -- Simulate hot-reload churn: bump the manager's reload generation if
        -- present, toggle internal state; the entry-installed wrappers are not
        -- part of that machinery and must be untouched.
        if sb.Mods._relay then sb.Mods._relay._reload_generation = (sb.Mods._relay._reload_generation or 0) + 1 end
        if sb.Mods and sb.Mods._manager then sb.Mods._manager._generation = (sb.Mods._manager._generation or 0) + 1 end

        runner.assert_eq(wrapper_print, sb.print, "print wrapper identity stable across reload churn")
        runner.assert_eq(wrapper_dunder, sb.__print, "__print wrapper identity stable across reload churn")

        sb.print("after-reload")
        runner.assert_eq(1, #sink_log, "wrapper still functional after simulated reload")
        runner.assert_eq("after-reload", sink_log[1], "capture still routes through the original wrapper")
    end)

    runner.register("lua-logs: a later mod replacing global print wins (wrapper does not fight it)", function()
        -- The tee is process-lifetime and non-stacking; it does NOT re-assert
        -- itself over a mod that rewrites global print after bootstrap.
        local sb = fresh_sb()
        local sink_log = {}
        sb.print = function() end
        sb.__mod_relay_lua_log_sink = sink_recorder(sink_log)
        mock.load_module("init", sb)()
        local tee_wrapper = sb.print
        clear(sink_log)

        local mod_log = {}
        sb.print = function(...) mod_log[#mod_log + 1] = "mod-print" end  -- a mod overrides print
        sb.print("hi")
        runner.assert_eq(0, #sink_log, "the mod's replacement print is NOT tee'd (mod wins)")
        runner.assert_eq(1, #mod_log, "the mod's print ran")
        -- The original tee wrapper still exists (retained by __print or by
        -- closure), but it is no longer the global — we do not fight the mod.
        runner.assert_truthy(tee_wrapper ~= sb.print, "global print is now the mod's function")
    end)
end
