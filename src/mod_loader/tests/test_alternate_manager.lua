-- test_alternate_manager.lua — the manager-slot override (RELAY_MOD_MANAGER /
-- --mod-manager): init.lua's snapshot of the trampoline-baked global, the
-- raw-io chunk seam (Mods._relay.load_chunk), and lifecycle Step 1a/1b
-- alternate selection + failure gating — retry before engine-ready, hard
-- exit after (ffi ExitProcess(1) -> os.exit(1) -> contained raise), never
-- continuing managerless under a configured alternate.
--
-- The built-in path is proven byte-identical by the existing suite; these
-- tests additionally pin the fork (no configured path -> built-in requested).

local mock = require("mock")

return function(runner)
    local function count_sub(lines, sub)
        local n = 0
        for _, line in ipairs(lines) do
            if type(line) == "string" and line:find(sub, 1, true) then n = n + 1 end
        end
        return n
    end

    local function count_events(timeline, tag)
        local n = 0
        for _, ev in ipairs(timeline) do
            if ev[1] == tag then n = n + 1 end
        end
        return n
    end

    local function first_event(timeline, tag)
        for _, ev in ipairs(timeline) do
            if ev[1] == tag then return ev end
        end
        return nil
    end

    local function count_exact(list, want)
        local n = 0
        for _, item in ipairs(list) do
            if item == want then n = n + 1 end
        end
        return n
    end

    -- -----------------------------------------------------------------
    -- init.lua: the trampoline-global snapshot + the chunk seam
    -- -----------------------------------------------------------------

    -- Run the REAL entry with a (possibly absent) baked RELAY_MOD_MANAGER.
    local function setup_entry(opts)
        opts = opts or {}
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.MOD_RELAY_VERSION = "0.3.0-beta.2"
        if opts.manager ~= nil then
            sb.RELAY_MOD_MANAGER = opts.manager
        end
        sb.require = function() return {} end
        sb.print = function() end
        sb.io = mock.make_io(mock.stage_mod_loader())
        mock.load_module("init", sb)()
        return sb
    end

    runner.register("alternate: entry snapshots a non-empty RELAY_MOD_MANAGER + retires the global", function()
        local sb = setup_entry({ manager = "C:\\tools\\alt manager.lua" })
        runner.assert_eq("C:\\tools\\alt manager.lua", sb.Mods._relay.mod_manager_path,
            "the configured path is snapshotted verbatim")
        runner.assert_nil(sb.RELAY_MOD_MANAGER,
            "the trampoline global must be retired")
    end)

    runner.register("alternate: entry maps an empty RELAY_MOD_MANAGER to nil + retires the global", function()
        local sb = setup_entry({ manager = "" })
        runner.assert_nil(sb.Mods._relay.mod_manager_path,
            "the empty string means no alternate (built-in)")
        runner.assert_nil(sb.RELAY_MOD_MANAGER)
    end)

    runner.register("alternate: entry is nil-safe when RELAY_MOD_MANAGER is absent (older shell)", function()
        local sb = setup_entry({})
        runner.assert_nil(sb.Mods._relay.mod_manager_path)
        runner.assert_nil(sb.RELAY_MOD_MANAGER)
        runner.assert_eq(true, sb.Mods._loaded,
            "the entry completes unchanged when the global is absent")
        runner.assert_type("function", sb.Mods.coordinate_bootstrap,
            "lifecycle loaded through the extracted chunk helper (no behavior change)")
    end)

    runner.register("alternate: load_chunk loads an arbitrary path raw; returns (ok, result, mode)", function()
        local files = mock.stage_mod_loader()
        files["/custom/thing.lua"] = "return { marker = 'custom-chunk' }"
        files["/custom/bad.lua"] = "this is not ( valid lua"
        files["/custom/raises.lua"] = "error('chunk boom')"
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.MOD_RELAY_VERSION = "0.3.0-beta.2"
        sb.require = function() return {} end
        sb.print = function() end
        sb.io = mock.make_io(files)
        mock.load_module("init", sb)()

        local ok, result, mode = sb.Mods._relay.load_chunk("/custom/thing.lua")
        runner.assert_eq(true, ok, "a loadable chunk succeeds")
        runner.assert_eq({ marker = "custom-chunk" }, result, "the chunk's return value passes through")
        runner.assert_nil(mode, "no failure mode on success")

        local ok2, r2, mode2 = sb.Mods._relay.load_chunk("/custom/absent.lua")
        runner.assert_eq(false, ok2)
        runner.assert_nil(r2)
        runner.assert_eq("open", mode2, "missing file reports the open mode")

        local ok3, r3, mode3 = sb.Mods._relay.load_chunk("/custom/bad.lua")
        runner.assert_eq(false, ok3)
        runner.assert_eq("parse", mode3, "a syntax error reports the parse mode")

        local ok4, r4, mode4 = sb.Mods._relay.load_chunk("/custom/raises.lua")
        runner.assert_eq(false, ok4)
        runner.assert_eq("run", mode4, "a raising chunk reports the run mode")
    end)

    runner.register("alternate: load_chunk uses the raw io.open captured before file.lua's wrapper installs", function()
        -- After the entry runs, booby-trap every reachable io.open surface.
        -- load_chunk must keep working: it captured the raw function VALUE at
        -- entry time (pre-wrap), so later field replacement cannot reach it —
        -- an alternate path can never be silently routed through the
        -- mod-root-rooting wrapper.
        local files = mock.stage_mod_loader()
        files["/custom/raw.lua"] = "return { ok = true }"
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.MOD_RELAY_VERSION = "0.3.0-beta.2"
        sb.require = function() return {} end
        sb.print = function() end
        sb.io = mock.make_io(files)
        mock.load_module("init", sb)()
        local boom = function() error("io.open was re-read; the raw capture leaked") end
        sb.io.open = boom
        sb.Mods.lua.io.open = boom
        local pok, cok, cres = pcall(function()
            return sb.Mods._relay.load_chunk("/custom/raw.lua")
        end)
        runner.assert_eq(true, pok, "load_chunk must not re-read any io.open field")
        runner.assert_eq(true, cok, "the load itself succeeded through the captured open")
        runner.assert_eq(true, cres and cres.ok, "the raw captured open still serves the read")
    end)

    -- -----------------------------------------------------------------
    -- lifecycle Step 1a/1b: selection + failure gating (mocked chunk seam)
    -- -----------------------------------------------------------------
    -- Loads class_registry + lifecycle with the alternate configured and a
    -- FAKE Mods._relay.load_chunk (init.lua publishes the real one); a shared
    -- timeline records log lines + exit-surface invocations. opts: manager
    -- (path; default mock.MOD_MANAGER_PATH), builtin (no alternate), chunk
    -- ("ok" | "missing" | "parse" | "run" | "notable" | "new_error" |
    -- function(path) -> (ok, r, mode); default "ok"), exit_surfaces ("ffi" |
    -- "os" | "both" | "none"; default "ffi"), ffi_surface (explicit
    -- Mods.lua.ffi), no_engine_classes (steps 2-4 cannot wrap; engine-ready
    -- never satisfied).
    local function setup_lifecycle(opts)
        opts = opts or {}
        local manager_path = (opts.manager ~= nil) and opts.manager or mock.MOD_MANAGER_PATH
        if opts.builtin then
            manager_path = nil
        end
        local sb = mock.new_sandbox()
        sb.Mods = {}
        if manager_path ~= nil then
            sb.Mods._relay = { mod_manager_path = manager_path }
        end
        mock.attach_logger(sb)
        sb.Mods._relay.version = "0.3.0-test"
        sb.Crashify = { print_property = function() end }
        sb.Managers = {}
        sb.class = function(name) return { name = name } end

        local timeline = {}
        local logged = {}
        local function record_log(m)
            logged[#logged + 1] = m
            timeline[#timeline + 1] = { "log", m }
        end
        sb.__print = record_log

        local surfaces = opts.exit_surfaces or "ffi"
        local ffi_mock, os_mock
        if surfaces == "ffi" or surfaces == "both" then
            ffi_mock = {
                cdef = function(decl) timeline[#timeline + 1] = { "cdef", decl } end,
                C = { ExitProcess = function(code)
                    timeline[#timeline + 1] = { "exit-ffi", code }
                end },
            }
        end
        if surfaces == "os" or surfaces == "both" then
            os_mock = { exit = function(code) timeline[#timeline + 1] = { "exit-os", code } end }
        end
        if opts.ffi_surface then
            ffi_mock = opts.ffi_surface
        end
        sb.Mods.lua = { ffi = ffi_mock, os = os_mock }

        -- The alternate class under test (chunk "ok").
        local updates = {}
        local alt_instance
        local alt_class = {
            new = function()
                alt_instance = {
                    update = function(_, dt) updates[#updates + 1] = dt end,
                    on_game_state_changed = function() end,
                }
                return alt_instance
            end,
        }

        local chunk_behavior = opts.chunk or "ok"
        local chunk_calls = {}
        sb.Mods._relay.load_chunk = function(path)
            chunk_calls[#chunk_calls + 1] = path
            if type(chunk_behavior) == "function" then
                return chunk_behavior(path)
            end
            if chunk_behavior == "missing" then return false, nil, "open" end
            if chunk_behavior == "parse" then return false, nil, "parse" end
            if chunk_behavior == "run" then return false, nil, "run" end
            if chunk_behavior == "notable" then return true, nil end
            if chunk_behavior == "new_error" then
                return true, { new = function() error("alternate :new() boom") end }
            end
            return true, alt_class
        end

        -- load_module serves the REAL dmf_adapter (lifecycle's module scope +
        -- the chassis step read it); any built-in mod_manager request is
        -- counted (it must stay 0 under an alternate).
        local builtin_loads = 0
        sb.Mods.load_module = function(name)
            if name == "dmf_adapter" then
                return mock.run_module("dmf_adapter", sb)
            end
            if name == "mod_manager" then
                builtin_loads = builtin_loads + 1
                return nil
            end
        end

        mock.run_module("class_registry", sb)
        mock.run_module("lifecycle", sb)
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        local sg = nil
        if not opts.no_engine_classes then
            sg = sb.class("StateGame")
            sg.update = function() end
            local gsm = sb.class("GameStateMachine")
            gsm._change_state = function(self, n) self._state = { name = n } end
            gsm.current_state_name = function(self)
                return self._state and self._state.name or nil
            end
            gsm.destroy = function() end
        end
        sb.Mods.coordinate_bootstrap()

        local rec = {
            sb = sb, bsr = bsr, sg = sg,
            timeline = timeline, logged = logged,
            chunk_calls = chunk_calls,
            builtin_loads = function() return builtin_loads end,
            alt_class = alt_class,
            alt_instance = function() return alt_instance end,
            updates = updates,
        }
        return rec
    end

    runner.register("alternate: happy path — alternate instance in the slot; chassis duties run; bootstrap completes", function()
        local rec = setup_lifecycle({})
        rec.bsr._state_update(rec.bsr)
        local mm = rec.sb.Managers.mod
        runner.assert_not_nil(mm, "the manager was created")
        runner.assert_eq(rec.alt_instance(), mm, "Managers.mod is the alternate instance (identity)")
        runner.assert_eq(1, #rec.chunk_calls, "the alternate was loaded exactly once")
        runner.assert_eq(mock.MOD_MANAGER_PATH, rec.chunk_calls[1],
            "the configured path is handed to the chunk seam VERBATIM")
        runner.assert_eq(0, rec.builtin_loads(), "the built-in manager is never requested")
        -- Step 1c chassis duties ran over the alternate instance (it has no
        -- _adapter of its own, so the chassis-constructed dmf_adapter drove
        -- establish: _settings restored).
        runner.assert_type("table", rawget(mm, "_settings"), "chassis establish ran")
        runner.assert_eq(false, mm._settings.developer_mode)
        runner.assert_nil(rawget(mm, "_adapter"),
            "the chassis adapter instance is not stored on the manager")
        -- The StateGame wrap drives the alternate update; a later tick
        -- short-circuits (completed) without re-loading.
        rec.sg.update(rec.sg, 0.5)
        runner.assert_eq({ 0.5 }, rec.updates, "the wrapped update drives the alternate manager")
        rec.bsr._state_update(rec.bsr)
        runner.assert_eq(1, #rec.chunk_calls, "completed flag prevents re-loading")
        runner.assert_eq(0, count_events(rec.timeline, "exit-ffi"), "no exit on the happy path")
    end)

    runner.register("alternate: no configured path -> the built-in manager is requested (fork unchanged)", function()
        local rec = setup_lifecycle({ builtin = true })
        rec.bsr._state_update(rec.bsr)
        runner.assert_eq(1, rec.builtin_loads(),
            "Step 1a requests the built-in mod_manager when no alternate is configured")
        runner.assert_eq(0, #rec.chunk_calls, "the alternate seam is never called")
        runner.assert_eq(1, count_sub(rec.logged, "mod_manager not yet loadable"),
            "the built-in retry diagnostic applies (fake returns nil)")
        runner.assert_eq(0, count_events(rec.timeline, "exit-ffi"), "no exit machinery without an alternate")
    end)

    -- Failure modes while the engine is NOT ready: retry + log-once + no exit.
    -- (For "new_error" the class LOADS once and :new() retries, so the chunk
    -- is not re-read; the other modes re-attempt the load every tick.)
    local before_ready_modes = {
        { chunk = "missing",   warn = "chunk load failed (open)",   calls = 3 },
        { chunk = "parse",     warn = "chunk load failed (parse)",  calls = 3 },
        { chunk = "run",       warn = "chunk load failed (run)",    calls = 3 },
        { chunk = "notable",   warn = "chunk did not return a class table", calls = 3 },
        { chunk = "new_error", warn = ":new() raised",              calls = 1 },
    }
    for _, m in ipairs(before_ready_modes) do
        runner.register("alternate: " .. m.chunk .. " before engine-ready -> retry + log-once + NO exit", function()
            local rec = setup_lifecycle({ chunk = m.chunk, no_engine_classes = true })
            local ok = pcall(function()
                rec.bsr._state_update(rec.bsr)
                rec.bsr._state_update(rec.bsr)
                rec.bsr._state_update(rec.bsr)
            end)
            runner.assert_eq(true, ok, "ticks must not raise")
            runner.assert_eq(m.calls, #rec.chunk_calls, "retried through the existing machinery")
            runner.assert_eq(0, rec.builtin_loads(), "the built-in is never requested under an alternate")
            runner.assert_eq(0, count_events(rec.timeline, "exit-ffi"), "no ffi exit before engine-ready")
            runner.assert_eq(0, count_events(rec.timeline, "exit-os"), "no os exit before engine-ready")
            runner.assert_eq(1, count_sub(rec.logged, m.warn), "the failure mode logs exactly once")
            runner.assert_eq(1, count_sub(rec.logged, "will retry until the engine is ready"),
                "the retry diagnostic appears exactly once")
            runner.assert_eq(1, count_sub(rec.logged, mock.MOD_MANAGER_PATH),
                "the configured path is in the diagnostics")
            runner.assert_nil(rec.sb.Managers.mod, "no manager was created")
        end)
    end

    runner.register("alternate: a second distinct failure mode logs once EACH (per-mode once-gate)", function()
        local calls = 0
        local rec = setup_lifecycle({
            no_engine_classes = true,
            chunk = function()
                calls = calls + 1
                if calls == 1 then return false, nil, "open" end
                return false, nil, "parse"
            end,
        })
        rec.bsr._state_update(rec.bsr)
        rec.bsr._state_update(rec.bsr)
        runner.assert_eq(1, count_sub(rec.logged, "chunk load failed (open)"),
            "the first mode logged once")
        runner.assert_eq(1, count_sub(rec.logged, "chunk load failed (parse)"),
            "the second mode ALSO logs (once per DISTINCT mode)")
        runner.assert_eq(0, count_events(rec.timeline, "exit-ffi"))
    end)

    runner.register("alternate: a RAISING chunk seam stays inside the gate (tracked, never an escape)", function()
        -- A corrupted/foreign load_chunk that raises instead of returning
        -- (false, ...) must still route through the failure gate — an escape
        -- would retry managerless forever, violating the operator semantics.
        local rec = setup_lifecycle({
            chunk = function() error("seam boom") end,
        })
        local ok1 = pcall(function() rec.bsr._state_update(rec.bsr) end)
        runner.assert_eq(true, ok1, "the raise is contained into a tracked failure")
        runner.assert_eq(1, count_sub(rec.logged, "the chunk seam raised"),
            "the seam failure is logged once")
        runner.assert_eq(0, count_events(rec.timeline, "exit-ffi"),
            "gate not yet satisfied on the first failing pass")
        rec.bsr._state_update(rec.bsr)  -- steps 2-4 wrapped -> engine-ready
        runner.assert_eq(1, count_events(rec.timeline, "exit-ffi"),
            "the repeated seam failure terminates at engine-ready")
    end)

    -- Failure modes once the engine IS ready: hard exit after the final ERROR.
    local at_ready_modes = {
        { chunk = "missing",   warn = "chunk load failed (open)" },
        { chunk = "parse",     warn = "chunk load failed (parse)" },
        { chunk = "run",       warn = "chunk load failed (run)" },
        { chunk = "notable",   warn = "chunk did not return a class table" },
        { chunk = "new_error", warn = ":new() raised" },
    }
    for _, m in ipairs(at_ready_modes) do
        runner.register("alternate: " .. m.chunk .. " at engine-ready -> hard exit (ERROR precedes the exit call)", function()
            local rec = setup_lifecycle({ chunk = m.chunk })
            -- Tick 1: the failure happens BEFORE steps 2-4 wrap in this pass,
            -- so the gate is not yet satisfied — no exit (two-attempt minimum).
            rec.bsr._state_update(rec.bsr)
            runner.assert_eq(0, count_events(rec.timeline, "exit-ffi"),
                "no exit on the first failing pass")
            runner.assert_eq(1, count_sub(rec.logged, m.warn), "the failure mode logged once")
            -- Tick 2: steps 2-4 wrapped during tick 1's pass -> the repeated
            -- failure is permanent -> terminate.
            local ok = pcall(function() rec.bsr._state_update(rec.bsr) end)
            runner.assert_eq(true, ok, "the exit call must not raise out of the boot tick")
            local final_log, exit_ev = nil, nil
            for i, ev in ipairs(rec.timeline) do
                if ev[1] == "log" and type(ev[2]) == "string"
                   and ev[2]:find("Relay is exiting", 1, true) and final_log == nil then
                    final_log = i
                end
                if ev[1] == "exit-ffi" and exit_ev == nil then
                    exit_ev = i
                end
            end
            runner.assert_not_nil(final_log, "the final ERROR was logged")
            runner.assert_not_nil(exit_ev, "ExitProcess was invoked")
            runner.assert_truthy(final_log < exit_ev,
                "the final ERROR precedes the exit call")
            runner.assert_eq(1, first_event(rec.timeline, "exit-ffi")[2],
                "ExitProcess called with exit code 1")
            runner.assert_eq(1, count_events(rec.timeline, "cdef"),
                "the ExitProcess cdef ran exactly once")
            runner.assert_eq(1, count_events(rec.timeline, "exit-ffi"),
                "the exit surface invoked exactly once")
            -- Later failures never re-invoke the exit surface.
            rec.bsr._state_update(rec.bsr)
            rec.bsr._state_update(rec.bsr)
            runner.assert_eq(1, count_events(rec.timeline, "exit-ffi"),
                "double failure does not re-invoke the exit surface")
            runner.assert_eq(1, count_events(rec.timeline, "cdef"),
                "the cdef is not re-attempted either")
        end)
    end

    runner.register("alternate: final ERROR names the configured path + the no-managerless policy", function()
        local rec = setup_lifecycle({ chunk = "missing" })
        rec.bsr._state_update(rec.bsr)
        rec.bsr._state_update(rec.bsr)
        local final_line = nil
        for _, line in ipairs(rec.logged) do
            if type(line) == "string" and line:find("Relay is exiting", 1, true) then
                final_line = line
                break
            end
        end
        runner.assert_not_nil(final_line, "final ERROR logged")
        runner.assert_truthy(final_line:find(mock.MOD_MANAGER_PATH, 1, true) ~= nil,
            "the configured path is named")
        runner.assert_truthy(final_line:find("must not continue without it", 1, true) ~= nil,
            "the policy (never continue managerless) is stated")
    end)

    runner.register("alternate: ffi unavailable -> os.exit(1) fallback", function()
        local rec = setup_lifecycle({ chunk = "missing", exit_surfaces = "os" })
        rec.bsr._state_update(rec.bsr)  -- fail (gate not yet satisfied) + wrap 2-4
        rec.bsr._state_update(rec.bsr)  -- gate satisfied -> final ERROR -> os.exit
        runner.assert_eq(0, count_events(rec.timeline, "exit-ffi"), "no ffi surface present")
        runner.assert_eq(1, count_events(rec.timeline, "exit-os"), "os.exit invoked")
        runner.assert_eq(1, first_event(rec.timeline, "exit-os")[2], "os.exit called with code 1")
        runner.assert_eq(1, count_sub(rec.logged, "Relay is exiting"), "final ERROR logged once")
        rec.bsr._state_update(rec.bsr)
        runner.assert_eq(1, count_events(rec.timeline, "exit-os"),
            "later failures do not re-invoke os.exit")
    end)

    runner.register("alternate: no exit surface at all -> contained raise, logged once, no spam", function()
        local rec = setup_lifecycle({ chunk = "missing", exit_surfaces = "none" })
        rec.bsr._state_update(rec.bsr)  -- fail + wrap 2-4
        local ok = pcall(function() rec.bsr._state_update(rec.bsr) end)
        runner.assert_eq(true, ok,
            "the raise is contained by the boot wrapper (the engine tick survives)")
        runner.assert_eq(1, count_sub(rec.logged, "Relay is exiting"),
            "the final ERROR fired exactly once")
        runner.assert_eq(1, count_sub(rec.logged, "bootstrap failed"),
            "the contained raise is logged exactly once")
        -- Ticks 3+: the attempted-once guard prevents re-raising / re-logging.
        local ok2 = pcall(function()
            rec.bsr._state_update(rec.bsr)
            rec.bsr._state_update(rec.bsr)
        end)
        runner.assert_eq(true, ok2, "later ticks raise nothing")
        runner.assert_eq(1, count_sub(rec.logged, "Relay is exiting"), "no repeated final ERROR")
        runner.assert_eq(1, count_sub(rec.logged, "bootstrap failed"), "no repeated containment log")
    end)

    runner.register("alternate: hard exit uses the FFI branch under the REAL engine ffi.C shape (userdata)", function()
        -- Production-shape pin: on the real engine (LuaJIT 2.1) ffi.C is a
        -- userdata cdata namespace, NOT a table. A guard that accepts only a
        -- table C silently disables the FFI exit branch in production (every
        -- exit falls through to the os fallback). The offline harness runs
        -- real LuaJIT, so this test pins the ACTUAL engine shape rather than
        -- a mock's.
        local real_ffi = require("ffi")
        runner.assert_eq("userdata", type(real_ffi.C),
            "precondition: the real engine's ffi.C is userdata")
        runner.assert_eq(true, (pcall(real_ffi.cdef, "void ExitProcess(unsigned int);")),
            "the real engine parses the ExitProcess cdef declaration")

        -- A module-shaped ffi surface with the production C TYPE but a
        -- recording exit (calling the real ffi.C.ExitProcess on a host where
        -- it resolves would end the harness process): C is userdata via
        -- newproxy + __index, and cdef records the attempt.
        local exits, cdefs, exit_code = 0, 0, nil
        local C = newproxy(true)
        getmetatable(C).__index = function(_, key)
            if key == "ExitProcess" then
                return function(code)
                    exits = exits + 1
                    exit_code = code
                end
            end
        end
        local rec = setup_lifecycle({
            chunk = "missing",
            exit_surfaces = "both",  -- os mock present: a guard regression
                                     -- falls through to it (visible below)
            ffi_surface = {
                cdef = function() cdefs = cdefs + 1 end,
                C = C,
            },
        })
        rec.bsr._state_update(rec.bsr)  -- fail (gate not yet satisfied)
        rec.bsr._state_update(rec.bsr)  -- gate satisfied -> final ERROR -> exit
        runner.assert_eq(1, cdefs,
            "the userdata C was ACCEPTED: the ExitProcess cdef ran (a table-only guard skips the FFI branch and this stays 0)")
        runner.assert_eq(1, exits, "ffi.C.ExitProcess invoked via the userdata namespace")
        runner.assert_eq(1, exit_code, "ExitProcess called with exit code 1")
        runner.assert_eq(0, count_events(rec.timeline, "exit-os"),
            "the os fallback was NOT needed (the FFI branch itself worked)")
    end)

    -- -----------------------------------------------------------------
    -- Full stack: the REAL entry + the REAL chunk seam (io-mock recorder)
    -- -----------------------------------------------------------------

    -- Run the REAL entry with RELAY_MOD_MANAGER baked and (optionally) the
    -- alternate chunk staged in the io files map at stage_key (forward-slashed
    -- for the mock's lookup). io.open is wrapped with a recorder so tests can
    -- assert the EXACT strings handed to the raw open. Returns sb, bsr, sg,
    -- opened (the recorded raw open paths, in order).
    local function setup_full(opts)
        opts = opts or {}
        local configured = opts.manager or mock.MOD_MANAGER_PATH
        local files = mock.stage_mod_loader()
        if opts.stage_chunk ~= nil then
            files[opts.stage_key or mock.MOD_MANAGER_PATH] = opts.stage_chunk
        end
        local opened = {}
        local io_t = mock.make_io(files)
        local real_open = io_t.open
        io_t.open = function(path, mode)
            opened[#opened + 1] = path
            return real_open(path, mode)
        end
        local sb = mock.new_sandbox()
        sb.MOD_LOADER_DIR = mock.MOD_LOADER_ROOT
        sb.RELAY_MOD_PATH = mock.MOD_ROOT
        sb.MOD_RELAY_VERSION = "0.3.0-beta.2"
        sb.RELAY_MOD_MANAGER = configured
        sb.Managers = {}  -- the engine's Managers table exists from early boot
        sb.require = function() return {} end
        sb.print = function() end
        -- The engine's class() global (class_registry wraps it once it
        -- exists). Simple prototypal fake, same shape the chassis tests use.
        sb.class = function(name)
            local meta = { name = name }
            meta.__index = meta
            meta.new = function(self, ...)
                local inst = setmetatable({}, meta)
                if meta.init then meta.init(inst, ...) end
                return inst
            end
            return meta
        end
        sb.io = io_t
        mock.load_module("init", sb)()
        sb.Mods.coordinate_bootstrap()
        local bsr = sb.class("BootStateRequireGameScripts")
        bsr._state_update = function() end
        local sg = sb.class("StateGame")
        sg.update = function() end
        local gsm = sb.class("GameStateMachine")
        gsm._change_state = function(self, n) self._state = { name = n } end
        gsm.current_state_name = function(self)
            return self._state and self._state.name or nil
        end
        gsm.destroy = function() end
        sb.Mods.coordinate_bootstrap()
        return sb, bsr, sg, opened
    end

    runner.register("alternate: full stack — the configured path reaches the RAW io.open VERBATIM (no rooting)", function()
        local configured = "Z:\\Alt Managers\\mgr file.lua"
        local chunk_src = "return { new = function() "
            .. "return { update = function() end, on_game_state_changed = function() end } "
            .. "end }"
        local sb, bsr, sg, opened = setup_full({
            manager = configured,
            -- The mock's lookup normalizes \ -> /; the staged KEY uses forward
            -- slashes while the configured path keeps its backslashes.
            stage_key = "Z:/Alt Managers/mgr file.lua",
            stage_chunk = chunk_src,
        })
        bsr._state_update(bsr)
        runner.assert_eq(1, count_exact(opened, configured),
            "the EXACT configured string is handed to the raw io.open (no normalization, no rooting)")
        runner.assert_eq(0, count_exact(opened, mock.MOD_LOADER_ROOT .. "/mod_manager.lua"),
            "the built-in manager file is never opened under an alternate")
        runner.assert_not_nil(sb.Managers.mod, "the alternate chunk produced the manager")
    end)

    runner.register("alternate: full stack — the alternate chunk drives the whole bootstrap to completion", function()
        local chunk_src = [[
ALT_INSTANCE = nil
ALT_UPDATES = {}
return {
    new = function()
        local inst = {
            update = function(self, dt) ALT_UPDATES[#ALT_UPDATES + 1] = dt end,
            on_game_state_changed = function(self) end,
        }
        ALT_INSTANCE = inst
        return inst
    end,
}
]]
        local sb, bsr, sg, opened = setup_full({ stage_chunk = chunk_src })
        bsr._state_update(bsr)
        runner.assert_eq(sb.ALT_INSTANCE, sb.Managers.mod,
            "Managers.mod is the alternate instance (identity)")
        runner.assert_type("table", rawget(sb.Managers.mod, "_settings"),
            "chassis Step-1c establish ran over the alternate instance")
        sg.update(sg, 0.25)
        runner.assert_eq({ 0.25 }, sb.ALT_UPDATES,
            "the StateGame wrap drives the alternate manager's update")
        bsr._state_update(bsr)  -- completed short-circuit
        runner.assert_eq(1, count_exact(opened, mock.MOD_MANAGER_PATH),
            "the alternate file was opened exactly once")
    end)

    runner.register("alternate: full stack — a missing alternate at engine-ready hard-exits via ffi", function()
        -- Nothing staged at MOD_MANAGER_PATH: the real chunk seam fails open,
        -- tick 1 wraps steps 2-4, tick 2 terminates. The harness require
        -- returns {} so the entry publishes an empty ffi table; inject the
        -- recording mock (lifecycle reads Mods.lua.ffi at CALL time).
        local sb, bsr = setup_full({})
        local exits, cdefs, exit_code = 0, 0, nil
        sb.Mods.lua.ffi = {
            cdef = function() cdefs = cdefs + 1 end,
            C = { ExitProcess = function(code)
                exits = exits + 1
                exit_code = code
            end },
        }
        bsr._state_update(bsr)
        runner.assert_eq(0, exits, "no exit on the first failing pass (two-attempt minimum)")
        runner.assert_nil(sb.Managers.mod, "no manager was created from the missing alternate")
        bsr._state_update(bsr)
        runner.assert_eq(1, exits, "ExitProcess invoked exactly once at engine-ready")
        runner.assert_eq(1, exit_code, "exit code 1")
        runner.assert_eq(1, cdefs, "the ExitProcess cdef ran exactly once")
        bsr._state_update(bsr)
        runner.assert_eq(1, exits, "later failures do not re-invoke the exit surface")
    end)
end
