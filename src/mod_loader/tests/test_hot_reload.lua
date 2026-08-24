-- test_hot_reload.lua — in-game hot reload behavior (src/mod_loader/mod_manager.lua
-- reload state machine + dmf_adapter.lua generation boundary).
--
-- Covers the developer-mode-gated, LEFT Ctrl + LEFT Shift + R reload: the
-- trigger-neutral request seam, the keyboard trigger (exact parity edge), the
-- two-frame teardown/replacement state machine, reload-data association keyed
-- by name, identity survival across generations, installation-aware IO
-- adaptation + single observer, stale-global retirement, the failure/best-effort
-- contract, and the no-double-unload shutdown invariant.
--
-- Adapter-level settings restoration / state-read / retirement unit coverage
-- lives in test_dmf_adapter.lua; this file exercises the manager-driven
-- end-to-end behavior.

local mock = require("mock")

return function(runner)
    -- Clear a sequence table in place (so closures capturing it keep working).
    local function clear(t)
        for i = #t, 1, -1 do t[i] = nil end
    end

    -- Count log lines containing a substring (plain find).
    local function count_log(logged, sub)
        local n = 0
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find(sub, 1, true) then n = n + 1 end
        end
        return n
    end

    local function find_log(logged, sub)
        for _, line in ipairs(logged) do
            if type(line) == "string" and line:find(sub, 1, true) then return line end
        end
        return nil
    end

    -- Collect every <kind> tag (e.g. ":on_reload") from a sequence of {tag,...}.
    local function only_tags(seq, sub)
        local out = {}
        for _, e in ipairs(seq) do
            if type(e[1]) == "string" and e[1]:find(sub, 1, true) then
                out[#out + 1] = e[1]
            end
        end
        return out
    end

    local function count_tag(seq, sub)
        return #only_tags(seq, sub)
    end

    -- ---------------------------------------------------------------------
    -- Shared setup: sandbox with fake class, mutable mods.lst/.mod state, a
    -- controllable keyboard, and (by default) developer_mode restored true.
    -- ---------------------------------------------------------------------
    local function setup(opts)
        opts = opts or {}
        local sb = mock.new_sandbox()

        local registry = {}
        local function declare(name, ...)
            local meta = { name = name }
            meta.__index = meta
            meta.new = function(self, ...)
                local instance = setmetatable({}, meta)
                if meta.init then meta.init(instance, ...) end
                return instance
            end
            registry[name] = meta
            return meta
        end
        sb.class = setmetatable({ _registry = registry },
            { __call = function(_, ...) return declare(...) end })

        sb.__print = opts.print or function() end
        sb.Managers = opts.managers or {}
        sb.Managers.dmf = sb.Managers.dmf or { persistent_tables = { mods = {} } }
        sb.Mods = { file = {}, _relay = { version = "0.2.0" } }
        mock.attach_logger(sb)
        -- The chassis (lifecycle.lua module scope) loads dmf_adapter exactly
        -- once and publishes it on Mods._relay.dmf_adapter; mod_manager's init
        -- reads it from there. Simulate that chassis load (the real wiring is
        -- covered by test_lifecycle).
        sb.Mods._relay.dmf_adapter = mock.run_module("dmf_adapter", sb)
        sb.Mods.require_store = {}
        sb.Crashify = {
            print_property = function() end,
            remove_print_property = function() end,
        }
        sb.Mods.file.add_observer = function() end
        -- class_registry owns the _G[class_name] retire surface (production
        -- loads it before dmf_adapter). Seed the contract so reload teardown
        -- routing through Mods.retire_class works.
        sb.Mods.retire_class = function(name)
            if type(name) == "string" then sb[name] = nil end
        end

        local dev_mode = opts.developer_mode
        if dev_mode == nil then dev_mode = true end
        sb.Application = {
            user_setting = function(key)
                if key == "mod_manager_settings" then
                    return { developer_mode = dev_mode }
                end
                return nil
            end,
        }

        -- Mutable order + mod files, so tests can simulate rescans/reorders/
        -- add/remove between generations. read_content_to_table/exec_with_return
        -- always read the live state.
        local state = opts.state or {
            order = { "alpha", "beta" },
            mods = {},
        }
        sb.Mods.file.read_content_to_table = function(path)
            runner.assert_eq("mods.lst", path, "scan must target mods.lst")
            return state.order
        end
        sb.Mods.file.exec_with_return = function(path)
            for name, mod in pairs(state.mods) do
                if path == name .. "/" .. name .. ".mod" then return mod end
            end
            return nil
        end

        -- Controllable keyboard. left shift (idx 2) + left ctrl (idx 3) are
        -- the only modifiers the poll sums; right shift/ctrl have distinct
        -- indexes the poll never queries (proving right modifiers can't fire).
        local kstate = { r = false, lshift = false, lctrl = false,
                         rshift = false, rctrl = false }
        sb.Keyboard = {
            button_index = function(name)
                local idx = { r = 1, ["left shift"] = 2, ["left ctrl"] = 3,
                              ["right shift"] = 4, ["right ctrl"] = 5 }
                return idx[name]
            end,
            pressed = function(i) if i == 1 then return kstate.r == true end return false end,
            button = function(i)
                if i == 2 then return (kstate.lshift == true) and 1 or 0 end
                if i == 3 then return (kstate.lctrl == true) and 1 or 0 end
                if i == 4 then return (kstate.rshift == true) and 1 or 0 end
                if i == 5 then return (kstate.rctrl == true) and 1 or 0 end
                return 0
            end,
        }

        return sb, state, kstate, registry
    end

    local function load_driver(sb)
        return mock.run_module("mod_manager", sb)
    end

    -- Tick update(0.016) until the active load pass finalizes (phased: the
    -- anchor tick loads nothing, then one entry per tick). Bounded; asserts
    -- completion. Returns the ticks driven.
    local function tick_to_done(mm, bound)
        bound = bound or 100
        local ticks = 0
        while not mm._adapter:is_load_done() do
            ticks = ticks + 1
            if ticks > bound then
                runner.fail("load pass did not finalize within " .. bound .. " ticks")
            end
            mm:update(0.016)
        end
        return ticks
    end

    -- Drive one full reload: the teardown tick, then the phased replacement
    -- pass to completion.
    local function reload_to_done(mm)
        mm:update(0.016)  -- teardown frame
        tick_to_done(mm)  -- anchor + one entry per tick
    end

    local function new_loaded(sb)
        local mm = load_driver(sb):new()
        -- Chassis Step-1c built-in path: the manager's own adapter establishes
        -- (Managers.mod publication + settings restore-if-nil). The real
        -- chassis wiring is covered by test_lifecycle.
        mm._adapter:establish()
        tick_to_done(mm)
        return mm
    end

    -- Like new_loaded, but also returns the ModManager class so a test can
    -- replace methods on the persistent class (the same table the instance's
    -- metatable __index points at).
    local function new_loaded_with_class(sb)
        local ModManager = load_driver(sb)
        local mm = ModManager:new()
        mm._adapter:establish()
        tick_to_done(mm)
        return mm, ModManager
    end

    -- A recording mod object. seq captures {tag, data} tuples for init/update/
    -- on_reload/on_unload/on_game_state_changed. opts customizes callbacks.
    local function recording_mod(name, seq, opts)
        opts = opts or {}
        return {
            init = function(self, data)
                -- Wrap in a table so nil data still records a countable entry.
                table.insert(seq, { name .. ":init", data })
                if opts.fail_init then error(name .. " init boom") end
            end,
            update = function(self, dt)
                table.insert(seq, { name .. ":update" })
            end,
            on_reload = function(self)
                table.insert(seq, { name .. ":on_reload" })
                if opts.fail_reload then error(name .. " on_reload boom") end
                return opts.reload_return
            end,
            on_unload = function(self)
                table.insert(seq, { name .. ":on_unload" })
                if opts.fail_unload then error(name .. " on_unload boom") end
            end,
            on_game_state_changed = function(self, status, sname)
                table.insert(seq, { name .. ":gsc:" .. status })
            end,
        }
    end

    local function mod_file(name, object)
        return { run = function() return object end }
    end

    local function stage(state, order, modmap)
        state.order = order
        state.mods = modmap or {}
    end

    -- ---------------------------------------------------------------------
    -- Trigger-neutral request seam (developer mode + done + no stacking)
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: request_reload enforces developer mode", function()
        local sb = setup({ developer_mode = false })
        local mm = new_loaded(sb)
        local ok, reason = mm:request_reload("test")
        runner.assert_eq(false, ok)
        runner.assert_truthy(reason and reason:find("developer") ~= nil)
        runner.assert_eq(false, mm._reload_requested, "no request recorded")
    end)

    runner.register("hot_reload: request_reload requires done state", function()
        local sb = setup()
        local mm = load_driver(sb):new()
        mm._adapter:establish()  -- chassis Step 1c (settings restored; not yet loaded)
        runner.assert_eq(false, mm._adapter:is_load_done())
        local ok, reason = mm:request_reload("test")
        runner.assert_eq(false, ok)
        runner.assert_truthy(reason and reason:find("done") ~= nil)
        runner.assert_eq(false, mm._reload_requested)
    end)

    runner.register("hot_reload: request_reload accepts when developer_mode + done", function()
        local sb = setup()
        local mm = new_loaded(sb)
        local ok = mm:request_reload("test")
        runner.assert_eq(true, ok)
        runner.assert_eq(true, mm._reload_requested)
    end)

    runner.register("hot_reload: request_reload rejects a second request before consumption", function()
        local sb = setup()
        local mm = new_loaded(sb)
        runner.assert_eq(true, mm:request_reload("test"))
        local ok, reason = mm:request_reload("test2")
        runner.assert_eq(false, ok, "second request before consumption rejected")
        runner.assert_truthy(reason and reason:find("active") ~= nil)
    end)

    runner.register("hot_reload: request during in-progress replacement is rejected (no wedge)", function()
        local sb, state = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        mm:request_reload("test")
        mm:update(0.016)  -- teardown frame -> _reload_in_progress set, _state nil
        runner.assert_eq(true, mm._reload_in_progress)
        runner.assert_eq(false, mm._adapter:is_load_done(),
            "state is nil during teardown -> done check rejects first")
        local ok = mm:request_reload("test")
        runner.assert_eq(false, ok, "request during teardown rejected")
        runner.assert_eq(false, mm._reload_requested,
            "rejected request must not record (no stacking/wedge)")
    end)

    -- ---------------------------------------------------------------------
    -- Keyboard trigger: exact LEFT Ctrl + LEFT Shift + R edge
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: LEFT Ctrl+Shift+R requests exactly one reload", function()
        local sb, state, kstate = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        kstate.r = true; kstate.lshift = true; kstate.lctrl = true
        mm:update(0.016)  -- poll -> request -> teardown frame
        runner.assert_eq(true, mm._reload_in_progress,
            "exact combo consumed the request and entered teardown")
        runner.assert_eq(false, mm._reload_requested, "request consumed in the same frame")
        kstate.r = false; kstate.lshift = false; kstate.lctrl = false
        tick_to_done(mm)  -- replacement replay
        runner.assert_eq("done", mm._state)
        runner.assert_eq(2, mm._generation)
    end)

    runner.register("hot_reload: R without modifiers does not request", function()
        local sb, state, kstate = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        kstate.r = true
        mm:update(0.016)
        runner.assert_eq(false, mm._reload_requested)
        runner.assert_eq(false, mm._reload_in_progress)
    end)

    runner.register("hot_reload: modifiers without R do not request", function()
        local sb, state, kstate = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        kstate.lshift = true; kstate.lctrl = true
        mm:update(0.016)
        runner.assert_eq(false, mm._reload_requested)
    end)

    runner.register("hot_reload: only one left modifier held (sum=1) does not request", function()
        local sb, state, kstate = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        kstate.r = true; kstate.lshift = true
        mm:update(0.016)
        runner.assert_eq(false, mm._reload_requested)
    end)

    runner.register("hot_reload: RIGHT modifiers + R do not request (left-only parity)", function()
        local sb, state, kstate = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        kstate.r = true; kstate.rshift = true; kstate.rctrl = true
        mm:update(0.016)
        runner.assert_eq(false, mm._reload_requested,
            "right modifiers must not satisfy the left-modifier sum")
    end)

    runner.register("hot_reload: developer_mode false never triggers via keyboard", function()
        local sb, state, kstate = setup({ developer_mode = false })
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        kstate.r = true; kstate.lshift = true; kstate.lctrl = true
        mm:update(0.016)
        runner.assert_eq(false, mm._reload_requested)
        runner.assert_eq(false, mm._reload_in_progress)
    end)

    -- ---------------------------------------------------------------------
    -- Keyboard robustness: missing / late / throwing never breaks update
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: missing Keyboard never breaks update (non-spamming log)", function()
        local sb, state = setup()
        sb.Keyboard = nil
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        local mm = new_loaded(sb)
        runner.assert_eq("done", mm._state, "load still completes")
        mm:update(0.016); mm:update(0.016); mm:update(0.016)
        runner.assert_eq(1, count_log(logged, "shortcut unavailable"),
            "unavailable logged once, not per-frame")
    end)

    runner.register("hot_reload: throwing Keyboard.button_index degrades non-spammingly", function()
        local sb, state = setup()
        sb.Keyboard = {
            button_index = function() error("nope") end,
            pressed = function() end, button = function() end,
        }
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        local mm = new_loaded(sb)
        runner.assert_eq("done", mm._state)
        mm:update(0.016); mm:update(0.016)
        runner.assert_eq(1, count_log(logged, "shortcut unavailable"))
    end)

    runner.register("hot_reload: throwing Keyboard.pressed degrades non-spammingly", function()
        local sb, state = setup()
        sb.Keyboard = {
            button_index = function(name)
                if name == "r" then return 1 end
                if name == "left shift" then return 2 end
                if name == "left ctrl" then return 3 end
            end,
            pressed = function() error("pressed boom") end,
            button = function() return 0 end,
        }
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        local mm = new_loaded(sb)
        runner.assert_eq("done", mm._state, "update survives the throwing query")
        mm:update(0.016); mm:update(0.016)
        runner.assert_eq(1, count_log(logged, "shortcut unavailable"))
    end)

    runner.register("hot_reload: late Keyboard availability can eventually trigger", function()
        local sb, state, kstate = setup()
        sb.Keyboard = nil
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        mm:update(0.016)  -- absent; logged once, no request
        runner.assert_eq(false, mm._reload_requested)
        sb.Keyboard = {
            button_index = function(name)
                local idx = { r = 1, ["left shift"] = 2, ["left ctrl"] = 3 }
                return idx[name]
            end,
            pressed = function(i) if i == 1 then return kstate.r == true end return false end,
            button = function(i)
                if i == 2 then return (kstate.lshift == true) and 1 or 0 end
                if i == 3 then return (kstate.lctrl == true) and 1 or 0 end
                return 0
            end,
        }
        kstate.r = true; kstate.lshift = true; kstate.lctrl = true
        mm:update(0.016)  -- late resolution + trigger
        runner.assert_eq(true, mm._reload_in_progress,
            "late-available keyboard eventually triggers a reload")
    end)

    -- ---------------------------------------------------------------------
    -- Teardown/replacement ordering + frame boundary
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: on_reload forward order, on_unload reverse order", function()
        local sb, state = setup()
        local seq = {}
        stage(state, { "alpha", "beta", "gamma" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq)),
            beta = mod_file("beta", recording_mod("beta", seq)),
            gamma = mod_file("gamma", recording_mod("gamma", seq)),
        })
        local mm = new_loaded(sb)
        mm:request_reload("test")
        mm:update(0.016)  -- teardown frame
        runner.assert_eq(
            { "alpha:on_reload", "beta:on_reload", "gamma:on_reload" },
            only_tags(seq, ":on_reload"), "on_reload fires in forward load order")
        runner.assert_eq(
            { "gamma:on_unload", "beta:on_unload", "alpha:on_unload" },
            only_tags(seq, ":on_unload"), "on_unload fires in reverse load order")
    end)

    runner.register("hot_reload: teardown frame runs no mod updates; replacement frame loads+drives", function()
        local sb, state = setup()
        local seq = {}
        stage(state, { "alpha", "beta" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq)),
            beta = mod_file("beta", recording_mod("beta", seq)),
        })
        local mm = new_loaded(sb)
        clear(seq)
        mm:request_reload("test")
        mm:update(0.016)  -- teardown frame: on_reload/on_unload only, NO update
        runner.assert_eq(0, count_tag(seq, ":update"),
            "no mod update may run in the teardown frame")
        runner.assert_nil(mm._state, "state is nil during teardown")
        tick_to_done(mm)  -- replacement replay
        runner.assert_eq("done", mm._state)
        runner.assert_eq(2, mm._generation)
        runner.assert_truthy(count_tag(seq, ":init") >= 2, "replacement replay ran init")
        runner.assert_truthy(count_tag(seq, ":update") >= 2,
            "the replay drove new-generation updates as entries came up")
    end)

    runner.register("hot_reload: no old update/state callback after teardown begins", function()
        local sb, state = setup()
        local seq = {}
        local old_alpha = recording_mod("alpha", seq)
        stage(state, { "alpha" }, { alpha = mod_file("alpha", old_alpha) })
        local mm = new_loaded(sb)
        local new_alpha = recording_mod("alpha", seq)
        stage(state, { "alpha" }, { alpha = mod_file("alpha", new_alpha) })
        clear(seq)
        mm:request_reload("test")
        mm:update(0.016)  -- teardown: old_alpha on_reload + on_unload
        -- on_game_state_changed during teardown must be ignored (state not done).
        mm:on_game_state_changed("enter", "StateIngame", {})
        runner.assert_eq(0, count_tag(seq, ":gsc:"),
            "no outer state-change callback while not done")
        tick_to_done(mm)  -- replacement replay
        runner.assert_eq("done", mm._state)
        clear(seq)
        -- After done, a state change is forwarded to the NEW generation.
        mm:on_game_state_changed("enter", "StateIngame", {})
        runner.assert_eq(1, count_tag(seq, ":gsc:enter"),
            "after done, new-generation state callbacks fire")
    end)

    runner.register("hot_reload: phased replay — teardown tick, anchor tick, one entry per tick, completion on the final replay tick", function()
        -- Community-parity replacement pacing: the reload spans teardown (no
        -- loads) -> phase-0 anchor (pass-begin line, no entries) -> one entry
        -- per tick -> mark_load_done + generation increment + completion log
        -- all on the final replay tick. Reload requests are refused mid-replay
        -- and gsc stays suppressed until done; per-name reload_data still
        -- reaches the right entry.
        local logged = {}
        local sb, state = setup({ print = function(m) table.insert(logged, m) end })
        sb.Mods._relay._trace_enabled = true
        local seq = {}
        stage(state, { "alpha", "beta" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq, { reload_return = "alpha_data" })),
            beta = mod_file("beta", recording_mod("beta", seq, { reload_return = "beta_data" })),
        })
        local mm = new_loaded(sb)
        runner.assert_eq(1, mm._generation)

        mm:request_reload("test")
        clear(seq)
        mm:update(0.016)  -- teardown tick: on_reload/on_unload only
        runner.assert_eq(0, count_tag(seq, ":init"), "no loads in the teardown tick")

        mm:update(0.016)  -- anchor tick of the replacement pass
        runner.assert_eq(1, count_log(logged, "load pass begin (reload, generation 2)"),
            "the anchor tick logs the reload pass begin with its target generation")
        runner.assert_eq(0, count_tag(seq, ":init"), "the anchor tick loads no entries")
        runner.assert_eq(false, mm._adapter:is_load_done())

        -- Mid-replay: a reload request is refused and gsc is suppressed.
        runner.assert_eq(false, mm:request_reload("mid"),
            "reload request refused mid-replay (manager not done)")
        mm:on_game_state_changed("enter", "StateIngame", {})
        runner.assert_eq(0, count_tag(seq, ":gsc:"), "gsc suppressed during the replay")

        mm:update(0.016)  -- alpha's replay tick
        runner.assert_eq(1, count_tag(seq, ":init"), "exactly one entry loaded")
        runner.assert_eq(false, mm._adapter:is_load_done())
        runner.assert_eq(1, mm._generation, "generation advances only at finalize")
        runner.assert_eq(1, mm._mod_load_index,
            "_mod_load_index holds the replayed entry between its ticks")
        runner.assert_eq(0, count_log(logged, "load pass end (reload, generation 2)"),
            "no pass-end line before the finalize tick")

        mm:update(0.016)  -- beta's replay tick: last entry -> finalize
        runner.assert_eq(2, count_tag(seq, ":init"), "one init per entry across the replay")
        runner.assert_eq(true, mm._adapter:is_load_done())
        runner.assert_eq(2, mm._generation,
            "generation increments on the final replay tick")
        runner.assert_eq(1, count_log(logged, "hot reload generation 2 completed cleanly"),
            "the completion log lands on the final replay tick")
        runner.assert_eq(1, count_log(logged, "load pass end (reload, generation 2)"),
            "the pass-end TRACE lands exactly once, on the replay finalize tick")
        runner.assert_nil(mm._mod_load_index)

        -- Per-name reload_data still delivered to the right entry.
        local received = {}
        for _, e in ipairs(seq) do
            if e[1]:find(":init", 1, true) and e[2] ~= nil then
                received[e[1]:match("^(.-):init")] = e[2]
            end
        end
        runner.assert_eq("alpha_data", received.alpha)
        runner.assert_eq("beta_data", received.beta)
    end)

    runner.register("hot_reload: mid-replay framework drive failure finalizes degraded and skips the unloaded tail", function()
        -- A framework-boundary UPDATE failure on a MID-replay tick (later
        -- entries still unloaded) stops the replacement pass after that
        -- tick's load step: the pass finalizes on the NEXT tick reporting
        -- "completed with errors" (a stopped generation is never clean —
        -- load-time framework failures already set _pass_had_errors; this is
        -- the drive-time corner), the unloaded tail ends skipped, and the
        -- loaded outers reverse-unloaded exactly once on the failure tick.
        local logged = {}
        local seq = {}
        local sb, state = setup({ print = function(m) table.insert(logged, m) end })
        stage(state, { "prior", "dmf", "later" }, {
            prior = mod_file("prior", recording_mod("prior", seq)),
            dmf = mod_file("dmf", recording_mod("dmf", seq)),
            later = mod_file("later", recording_mod("later", seq)),
        })
        local mm = new_loaded(sb)
        runner.assert_eq(true, mm._adapter:is_load_done())

        -- Replacement generation: dmf loads fine, but its outer update raises
        -- a framework-boundary error as soon as the fan-out reaches it.
        stage(state, { "prior", "dmf", "later" }, {
            prior = mod_file("prior", recording_mod("prior", seq)),
            dmf = mod_file("dmf", {
                init = function() table.insert(seq, { "dmf:init" }) end,
                update = function() error("framework drive boom") end,
                on_unload = function() table.insert(seq, { "dmf:on_unload" }) end,
            }),
            later = mod_file("later", recording_mod("later", seq)),
        })
        clear(seq)
        mm:request_reload("test")
        mm:update(0.016)  -- teardown tick (gen-1 on_reload/on_unload)
        clear(seq)
        mm:update(0.016)  -- replay anchor tick (loads nothing)
        runner.assert_eq(0, count_tag(seq, ":init"), "anchor loads nothing")

        mm:update(0.016)  -- prior's replay tick (loads + first update)
        mm:update(0.016)  -- dmf's replay tick: loads fine, then its update raises
        runner.assert_eq(2, count_tag(seq, ":init"),
            "prior + dmf loaded; later still unloaded at the failure tick")
        runner.assert_eq(false, mm._adapter:is_load_done(),
            "the pass is still open at the end of the failure tick")
        runner.assert_eq(1, mm._generation, "generation advances only at finalize")
        runner.assert_eq({ "dmf:on_unload", "prior:on_unload" },
            only_tags(seq, ":on_unload"),
            "the failure tick's fan-out reverse-unloaded the loaded outers")
        runner.assert_not_nil(find_log(logged, "framework-boundary lifecycle failure"))

        mm:update(0.016)  -- finalize tick (stop honored; later never loads)
        runner.assert_eq(true, mm._adapter:is_load_done())
        runner.assert_eq(2, mm._generation)
        runner.assert_eq(2, count_tag(seq, ":init"), "later never initialized")
        runner.assert_eq("stopped", mm._mods[1].state)
        runner.assert_eq("disabled", mm._mods[2].state)
        runner.assert_eq("skipped", mm._mods[3].state,
            "the unloaded tail is skipped at finalize")
        runner.assert_eq(2, count_tag(seq, ":on_unload"),
            "each loaded outer unloaded exactly once (no later unload)")
        runner.assert_not_nil(find_log(logged,
            "hot reload generation 2 completed with errors; game restart recommended"),
            "the drive-time framework stop reports a degraded completion")
        runner.assert_eq(0, count_log(logged, "completed cleanly"),
            "a stopped generation is never a clean completion")
    end)

    runner.register("hot_reload: destroy mid-replay settles the reload machinery (no fresh pass)", function()
        -- destroy() is terminal: destroying during a replacement replay also
        -- settles the reload state, so a later update() drives no loads and
        -- cannot begin a fresh replacement pass over the stale reload data.
        local logged = {}
        local seq = {}
        local sb, state = setup({ print = function(m) table.insert(logged, m) end })
        sb.Mods._relay._trace_enabled = true
        stage(state, { "alpha", "beta" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq)),
            beta = mod_file("beta", recording_mod("beta", seq)),
        })
        local execd = 0
        local real_exec = sb.Mods.file.exec_with_return
        sb.Mods.file.exec_with_return = function(p)
            execd = execd + 1
            return real_exec(p)
        end
        local mm = new_loaded(sb)
        runner.assert_eq(true, mm._adapter:is_load_done())

        mm:request_reload("test")
        mm:update(0.016)  -- teardown tick
        mm:update(0.016)  -- replay anchor tick (loads nothing)
        runner.assert_eq(1, count_log(logged, "load pass begin (reload, generation 2)"))
        mm:update(0.016)  -- alpha's replay tick (beta still pending)
        runner.assert_eq(false, mm._adapter:is_load_done(), "pass still open mid-replay")

        mm:destroy()
        runner.assert_eq(false, mm._reload_in_progress, "destroy settles the reload flag")
        runner.assert_nil(mm._reload_data, "destroy clears the staged reload data")
        runner.assert_nil(mm._load_phase, "the pass bookkeeping is settled")
        runner.assert_nil(mm._mod_load_index)
        runner.assert_eq(false, mm._adapter:is_load_done(),
            "destroy is terminal, not a completion (no mark_load_done)")

        local execd_at_destroy = execd
        local ok, err = pcall(function()
            mm:update(0.016)
            mm:update(0.016)
        end)
        runner.assert_eq(true, ok, "post-destroy updates must not error: " .. tostring(err))
        runner.assert_eq(execd_at_destroy, execd, "no further .mod executed after destroy")
        runner.assert_eq(1, count_log(logged, "load pass begin (reload, generation 2)"),
            "no fresh replacement pass begins over the stale reload data")
        runner.assert_eq(0, count_log(logged, "load pass begin (reload, generation 3)"),
            "no later-generation pass begin either")
        runner.assert_eq("not_loaded", mm._mods[2].state, "the pending entry never loads")
        runner.assert_eq(false, mm._adapter:is_load_done())
    end)

    -- ---------------------------------------------------------------------
    -- Reload data association (keyed by name; startup nil)
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: startup init receives nil reload data", function()
        local sb, state = setup()
        local seen = {}
        stage(state, { "alpha" }, {
            alpha = { run = function()
                return {
                    -- Record each init as a wrapper table so nil data is countable.
                    init = function(self, data) table.insert(seen, { data = data }) end,
                    update = function() end,
                }
            end },
        })
        new_loaded(sb)
        runner.assert_eq(1, #seen, "init ran once on startup")
        runner.assert_nil(seen[1].data, "startup init receives nil reload data")
    end)

    runner.register("hot_reload: reload data keyed by name survives a reorder", function()
        local sb, state = setup()
        local seq = {}
        stage(state, { "alpha", "beta" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq, { reload_return = "alpha_data" })),
            beta = mod_file("beta", recording_mod("beta", seq, { reload_return = "beta_data" })),
        })
        local mm = new_loaded(sb)
        -- Reversed order for the replacement generation.
        stage(state, { "beta", "alpha" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq)),
            beta = mod_file("beta", recording_mod("beta", seq)),
        })
        mm:request_reload("test")
        reload_to_done(mm)
        local received = {}
        for _, e in ipairs(seq) do
            if e[1]:find(":init", 1, true) and e[2] ~= nil then
                received[e[1]:match("^(.-):init")] = e[2]
            end
        end
        runner.assert_eq("alpha_data", received.alpha,
            "alpha receives its own data (not beta's, despite reorder)")
        runner.assert_eq("beta_data", received.beta,
            "beta receives its own data (not alpha's, despite reorder)")
    end)

    runner.register("hot_reload: added mods receive nil; removed data is discarded", function()
        local sb, state = setup()
        local seq = {}
        stage(state, { "alpha", "beta" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq, { reload_return = "alpha_data" })),
            beta = mod_file("beta", recording_mod("beta", seq, { reload_return = "beta_data" })),
        })
        local mm = new_loaded(sb)
        stage(state, { "alpha", "gamma" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq)),
            gamma = mod_file("gamma", recording_mod("gamma", seq)),
        })
        mm:request_reload("test")
        reload_to_done(mm)
        local received = {}
        for _, e in ipairs(seq) do
            if e[1]:find(":init", 1, true) then
                received[e[1]:match("^(.-):init")] = e[2]
            end
        end
        runner.assert_eq("alpha_data", received.alpha, "alpha keeps its data")
        runner.assert_nil(received.gamma, "gamma (added) receives nil — no cross-data")
        runner.assert_nil(received.beta, "beta data discarded (not passed to anyone)")
    end)

    -- ---------------------------------------------------------------------
    -- mods.lst reread every reload; no implicit DMF injection
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: mods.lst is reread every reload (order is authoritative)", function()
        local sb, state = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        runner.assert_eq(1, #mm._mods)
        runner.assert_eq("alpha", mm._mods[1].name)
        stage(state, { "beta", "gamma" }, {
            beta = mod_file("beta", recording_mod("beta", {})),
            gamma = mod_file("gamma", recording_mod("gamma", {})),
        })
        mm:request_reload("test")
        reload_to_done(mm)
        runner.assert_eq(2, #mm._mods, "new order has two entries")
        runner.assert_eq("beta", mm._mods[1].name)
        runner.assert_eq("gamma", mm._mods[2].name)
    end)

    runner.register("hot_reload: no implicit DMF injection (DMF loads only if listed)", function()
        local sb, state = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        mm:request_reload("test")
        reload_to_done(mm)
        for _, entry in ipairs(mm._mods) do
            runner.assert_truthy(entry.name ~= "dmf", "dmf must not be implicitly injected")
        end
    end)

    runner.register("hot_reload: entry.data is re-executed + re-published per generation", function()
        -- The rescan rebuilds _mods fresh and _load_one re-executes each
        -- descriptor, so each generation's entry carries its OWN descriptor
        -- table (DMF reads .data during mod construction in run()).
        local sb, state = setup()
        local gen1 = mod_file("alpha", recording_mod("alpha", {}))
        stage(state, { "alpha" }, { alpha = gen1 })
        local mm = new_loaded(sb)
        runner.assert_eq(gen1, mm._mods[1].data,
            "generation 1 publishes its executed descriptor on the entry")
        local gen2 = mod_file("alpha", recording_mod("alpha", {}))
        stage(state, { "alpha" }, { alpha = gen2 })
        mm:request_reload("test")
        mm:update(0.016)  -- teardown (rescan rebuilds the entry tables)
        tick_to_done(mm)  -- replacement replay
        runner.assert_eq(2, mm._generation)
        runner.assert_eq(gen2, mm._mods[1].data,
            "generation 2 carries the freshly executed descriptor table")
    end)

    -- ---------------------------------------------------------------------
    -- Identity survival across THREE consecutive reload generations
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: manager/settings/require_store/CLASS/file/dmf identities survive 3 reloads", function()
        local sb, state = setup()
        -- Stage a REAL CLASS sentinel table (with content) so the identity +
        -- content assertions are non-vacuous (the manager must not replace or
        -- wipe CLASS across reload).
        local class_sentinel = { ModManager = "pre-existing-entry", tagged = true }
        sb.CLASS = class_sentinel
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        local settings_ref = mm._settings
        local require_store_ref = sb.Mods.require_store
        local class_ref = sb.CLASS
        local file_ref = sb.Mods.file
        local dmf_ref = sb.Managers.dmf
        local persistent_tables_ref = sb.Managers.dmf.persistent_tables
        local adapter_ref = mm._adapter

        runner.assert_eq(mm, sb.Managers.mod,
            "sanity: the manager is physically published at Managers.mod before reloads")

        for _ = 1, 3 do
            mm:request_reload("test")
            reload_to_done(mm)
            -- Assert the ORIGINAL manager is still the physically published
            -- reference each generation (not mm == mm).
            runner.assert_eq(mm, sb.Managers.mod,
                "the same manager is still published at Managers.mod after each generation")
            -- Assert the staged CLASS sentinel identity survives each generation.
            runner.assert_eq(class_sentinel, sb.CLASS,
                "the staged CLASS sentinel table identity survives each generation")
        end
        runner.assert_eq(4, mm._generation, "three reloads -> generation 4")
        runner.assert_eq(settings_ref, mm._settings, "_settings table identity survives")
        runner.assert_eq(require_store_ref, sb.Mods.require_store, "require_store survives")
        runner.assert_eq(class_ref, sb.CLASS, "CLASS table identity survives")
        runner.assert_eq(class_sentinel, sb.CLASS,
            "the exact staged CLASS sentinel table survives (not nil==nil)")
        runner.assert_eq("pre-existing-entry", sb.CLASS.ModManager,
            "CLASS content survives (ModManager entry intact, not an empty table)")
        runner.assert_eq(true, sb.CLASS.tagged, "CLASS content survives (tagged field intact)")
        runner.assert_eq(file_ref, sb.Mods.file, "Mods.file survives")
        runner.assert_eq(dmf_ref, sb.Managers.dmf, "Managers.dmf survives")
        runner.assert_eq(persistent_tables_ref, sb.Managers.dmf.persistent_tables,
            "persistent_tables survive")
        runner.assert_eq(adapter_ref, mm._adapter, "adapter instance survives")
        runner.assert_eq(true, mm._adapter:developer_mode_enabled(),
            "developer_mode still true after 3 reloads (settings not re-defaulted)")
    end)

    -- ---------------------------------------------------------------------
    -- Generation-aware IO + single observer (real file.lua integration)
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: each new DMFMod generation re-adapts; same-gen idempotent; observer count one", function()
        local sb = mock.new_sandbox()
        local registry = {}
        sb.class = function(name)
            local meta = { name = name }
            meta.__index = meta
            meta.new = function(self, ...)
                local inst = setmetatable({}, meta)
                if meta.init then meta.init(inst, ...) end
                return inst
            end
            registry[name] = meta
            return meta
        end
        sb.__print = function() end
        sb.Managers = { dmf = { persistent_tables = {} } }
        sb.Mods = { lua = {}, _mod_root = mock.MOD_ROOT, require_store = {} }
        mock.attach_logger(sb)
        -- class_registry owns the _G[class_name] retire surface (production
        -- loads it before dmf_adapter). Seed the contract so reload teardown
        -- routing through Mods.retire_class works.
        sb.Mods.retire_class = function(name)
            if type(name) == "string" then sb[name] = nil end
        end
        sb.Application = {
            user_setting = function(k)
                if k == "mod_manager_settings" then return { developer_mode = true } end
            end,
        }
        sb.Keyboard = {
            button_index = function() return 1 end,
            pressed = function() return false end,
            button = function() return 0 end,
        }
        local files = {}
        files[mock.MOD_ROOT .. "/mods.lst"] = ""
        files[mock.MOD_ROOT .. "/other.lua"] = "return 'other'"
        sb.Mods.lua.io = mock.make_io(files)
        sb.Mods.lua.loadstring = sb.loadstring
        -- file.lua loads path.lua via Mods.load_module at its module top; wire
        -- the generic source loader (dmf_adapter is NOT served through here —
        -- the chassis loads it exactly once, simulated below).
        sb.Mods.load_module = function(n) return mock.run_module(n, sb) end

        mock.run_module("file", sb)
        local observer_count = 0
        local real_add = sb.Mods.file.add_observer
        sb.Mods.file.add_observer = function(fn)
            observer_count = observer_count + 1
            real_add(fn)
        end

        -- Simulate the chassis module-scope load (published on Mods._relay),
        -- then load the real mod_manager.
        sb.Mods._relay.dmf_adapter = mock.run_module("dmf_adapter", sb)
        mock.run_module("mod_manager", sb)
        local mm = registry.ModManager:new()
        -- Chassis Step-1c built-in path: the manager's own adapter establishes
        -- + registers the real observer (exactly one registering instance).
        mm._adapter:establish()
        mm._adapter:register_io_observer()
        mm:update(0.016)  -- initial load (empty mods.lst -> done, no mods)
        runner.assert_eq(1, observer_count, "exactly one observer registered at chassis establishment")
        runner.assert_nil(mm._adapter:adapted_dmfmod())

        -- Surface a synthetic DMFMod (mirrors DMF core/io.lua defining io_*).
        local function define_dmfmod_gen()
            files[mock.MOD_ROOT .. "/dmf/core/io.lua"] = table.concat({
                "DMFMod = {}",
                "function DMFMod:io_dofile(p) return 'WRONG:' .. p end",
            }, "\n")
            sb.Mods.file.dofile("dmf/core/io")
        end

        define_dmfmod_gen()
        local gen1 = sb.DMFMod
        runner.assert_eq(gen1, mm._adapter:adapted_dmfmod(), "gen1 adapted")
        -- Same-generation idempotence: fire the observer WITHOUT redefining
        -- DMFMod (exec an unrelated file). The adapter must not re-adapt.
        local gen1_io_dofile = gen1.io_dofile
        sb.Mods.file.dofile("other")
        runner.assert_eq(gen1, sb.DMFMod, "sanity: DMFMod table unchanged")
        runner.assert_eq(gen1_io_dofile, sb.DMFMod.io_dofile,
            "same DMFMod table not re-adapted on a plain observer fire")

        -- Three reload generations; each defines a fresh DMFMod that must be
        -- re-adapted, and no extra observer is registered.
        for i = 1, 3 do
            mm:request_reload("test")
            mm:update(0.016)  -- teardown: retire clears _G.DMFMod
            runner.assert_nil(sb.DMFMod, "gen globals retired at teardown")
            define_dmfmod_gen()  -- new DMF scripts redefine DMFMod before Phase 2
            runner.assert_truthy(sb.DMFMod ~= gen1, "sanity: new DMFMod table")
            mm:update(0.016)  -- replacement
            runner.assert_eq(sb.DMFMod, mm._adapter:adapted_dmfmod(),
                "gen " .. (i + 1) .. " adapted before simulated Phase 2")
            gen1 = sb.DMFMod
        end
        runner.assert_eq(1, observer_count,
            "observer count still one after 3 reload generations")
    end)

    -- ---------------------------------------------------------------------
    -- Stale global retirement at the boundary; persistent tables not cleared
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: stale DMF globals retired at teardown; new definitions work after", function()
        local sb, state = setup()
        sb.DMFMod = { old = true }
        sb.new_mod = function() end
        sb.get_mod = function() end
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        runner.assert_not_nil(sb.DMFMod)
        mm:request_reload("test")
        mm:update(0.016)  -- teardown
        runner.assert_nil(sb.DMFMod, "DMFMod retired at teardown boundary")
        runner.assert_nil(sb.new_mod)
        runner.assert_nil(sb.get_mod)
        runner.assert_not_nil(sb.Managers.dmf.persistent_tables,
            "persistent tables untouched by retirement")
        tick_to_done(mm)  -- replacement replay
        runner.assert_eq("done", mm._state)
        -- New definitions work after retirement.
        sb.DMFMod = { new_gen = true }
        runner.assert_eq(true, sb.DMFMod.new_gen)
    end)

    -- ---------------------------------------------------------------------
    -- Failure / best-effort contract
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: on_reload failure marks degraded; teardown continues; restart recommended", function()
        local sb, state = setup()
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        local seq = {}
        stage(state, { "alpha", "beta" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq, { fail_reload = true })),
            beta = mod_file("beta", recording_mod("beta", seq)),
        })
        local mm = new_loaded(sb)
        mm:request_reload("test")
        mm:update(0.016)  -- teardown
        tick_to_done(mm)  -- replacement replay completes degraded
        runner.assert_eq("done", mm._state, "completes despite on_reload failure")
        runner.assert_eq(2, mm._generation)
        runner.assert_truthy(find_log(logged, "on_reload failed") ~= nil)
        runner.assert_truthy(find_log(logged, "restart recommended") ~= nil,
            "degraded completion recommends restart")
        runner.assert_eq(2, count_tag(seq, ":on_unload"),
            "reverse teardown continued past the on_reload failure")
    end)

    runner.register("hot_reload: on_unload failure marks degraded; reverse teardown continues", function()
        local sb, state = setup()
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        local seq = {}
        stage(state, { "alpha", "beta" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq, { fail_unload = true })),
            beta = mod_file("beta", recording_mod("beta", seq)),
        })
        local mm = new_loaded(sb)
        mm:request_reload("test")
        reload_to_done(mm)
        runner.assert_eq("done", mm._state)
        runner.assert_truthy(find_log(logged, "on_unload failed") ~= nil)
        runner.assert_truthy(find_log(logged, "restart recommended") ~= nil)
        -- Both on_unload ran (alpha failed, beta ok) + both on_reload ran.
        runner.assert_eq(2, count_tag(seq, ":on_unload"))
    end)

    runner.register("hot_reload: rescan failure -> empty set, degraded, completes without wedging", function()
        local sb, state = setup()
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        sb.Mods.file.read_content_to_table = function() return false end
        mm:request_reload("test")
        reload_to_done(mm)
        runner.assert_eq(0, #mm._mods, "empty mod set after failed rescan")
        runner.assert_eq("done", mm._state, "still reaches done")
        runner.assert_eq(2, mm._generation)
        runner.assert_truthy(find_log(logged, "missing or unreadable") ~= nil)
        runner.assert_truthy(find_log(logged, "restart recommended") ~= nil)
    end)

    runner.register("hot_reload: per-mod run failure isolated; pass continues; degraded", function()
        local sb, state = setup()
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        local seq = {}
        stage(state, { "alpha", "boom", "gamma" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq)),
            boom = { run = function() error("run boom") end },
            gamma = mod_file("gamma", recording_mod("gamma", seq)),
        })
        local mm = new_loaded(sb)
        mm:request_reload("test")
        reload_to_done(mm)
        runner.assert_eq("done", mm._state)
        runner.assert_nil(mm._mods[2].object, "boom has no object after run failure")
        runner.assert_truthy(mm._mods[3].object ~= nil, "gamma still loaded (isolation)")
        runner.assert_truthy(find_log(logged, "run failed") ~= nil)
        runner.assert_truthy(find_log(logged, "restart recommended") ~= nil)
    end)

    runner.register("hot_reload: per-mod init failure isolated; pass continues; degraded", function()
        local sb, state = setup()
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        local seq = {}
        stage(state, { "alpha", "boom", "gamma" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq)),
            boom = mod_file("boom", recording_mod("boom", seq, { fail_init = true })),
            gamma = mod_file("gamma", recording_mod("gamma", seq)),
        })
        local mm = new_loaded(sb)
        mm:request_reload("test")
        reload_to_done(mm)
        runner.assert_eq("done", mm._state)
        runner.assert_nil(mm._mods[2].object, "boom object cleared after init failure")
        runner.assert_truthy(mm._mods[3].object ~= nil, "gamma still loaded (isolation)")
        runner.assert_truthy(find_log(logged, "init failed") ~= nil)
        runner.assert_truthy(find_log(logged, "restart recommended") ~= nil)
    end)

    runner.register("hot_reload: DMF framework replacement failure emits unmistakable framework log", function()
        local sb, state = setup()
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        stage(state, { "dmf", "alpha" }, {
            dmf = mod_file("dmf", recording_mod("dmf", {})),
            alpha = mod_file("alpha", recording_mod("alpha", {})),
        })
        local mm = new_loaded(sb)
        stage(state, { "dmf", "alpha" }, {
            dmf = { run = function() error("dmf framework boom") end },
            alpha = mod_file("alpha", recording_mod("alpha", {})),
        })
        mm:request_reload("test")
        reload_to_done(mm)
        runner.assert_eq("done", mm._state, "still completes")
        runner.assert_truthy(find_log(logged, "DMF FRAMEWORK LOAD FAILURE") ~= nil,
            "unmistakable framework-load failure emitted")
        runner.assert_truthy(find_log(logged, "restart recommended") ~= nil)
        runner.assert_truthy(mm._mods[2].object ~= nil,
            "alpha still loads (isolation continued past dmf failure)")
    end)

    runner.register("hot_reload: finalization never wedges — a later reload is possible after a failed one", function()
        local sb, state = setup()
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        stage(state, { "alpha" }, {
            alpha = mod_file("alpha", recording_mod("alpha", {}, { fail_reload = true })),
        })
        local mm = new_loaded(sb)
        runner.assert_eq(true, mm._adapter:is_load_done())
        mm:request_reload("test")
        reload_to_done(mm)
        runner.assert_eq("done", mm._state, "first reload settled to done")
        runner.assert_eq(false, mm._reload_requested, "request flag cleared")
        runner.assert_eq(false, mm._reload_in_progress, "in-progress flag cleared")
        runner.assert_eq(2, mm._generation)
        -- A second reload request must be accepted (not wedged).
        local ok = mm:request_reload("test2")
        runner.assert_eq(true, ok, "a later reload request is possible after a failed reload")
        reload_to_done(mm)
        runner.assert_eq("done", mm._state)
        runner.assert_eq(3, mm._generation)
    end)

    runner.register("hot_reload: unexpected load-step throw in the replacement pass finalizes without wedging", function()
        -- Inject an unexpected exception from the per-entry load step during
        -- the replacement pass (e.g. Mods.file.exec_with_return itself
        -- throwing rather than returning false). The protected finalization
        -- must ALWAYS settle state, load index, request/in-progress flags,
        -- and reload data; report the generation degraded with a restart
        -- recommendation; and leave the manager able to accept a later reload.
        local sb, state = setup()
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        runner.assert_eq(true, mm._adapter:is_load_done())

        mm:request_reload("test")
        mm:update(0.016)  -- teardown frame (loads nothing); sets in-progress
        runner.assert_eq(true, mm._reload_in_progress, "sanity: replacement pending")
        runner.assert_not_nil(mm._reload_data,
            "sanity: reload data staged for the replacement pass")

        -- Swap the per-entry load step to throw on the replacement pass only.
        local real_load_step = mm._load_pass_entry
        mm._load_pass_entry = function(self, phase, entry)
            error("induced load-step boom")
        end
        local ok_update = pcall(function() tick_to_done(mm) end)  -- replacement replay
        runner.assert_eq(true, ok_update, "update must not propagate the load-step throw")

        -- ALWAYS-finalized invariants, regardless of the throw.
        runner.assert_eq("done", mm._state, "_state published done despite the throw")
        runner.assert_eq(false, mm._reload_in_progress, "_reload_in_progress cleared")
        runner.assert_eq(false, mm._reload_requested, "_reload_requested cleared")
        runner.assert_nil(mm._reload_data, "_reload_data cleared")
        runner.assert_nil(mm._mod_load_index, "_mod_load_index cleared (defensive end_load_pass)")
        runner.assert_eq(2, mm._generation, "generation still incremented + reported")
        runner.assert_truthy(find_log(logged, "load pass error") ~= nil,
            "the unexpected throw details are logged")
        runner.assert_truthy(find_log(logged, "restart recommended") ~= nil,
            "degraded completion recommends restart")

        -- A later valid reload request must be accepted (no wedge). Restore the
        -- real load step so the subsequent replacement loads normally.
        mm._load_pass_entry = real_load_step
        local ok_req = mm:request_reload("test2")
        runner.assert_eq(true, ok_req, "a later reload request is accepted after the throw")
        reload_to_done(mm)
        runner.assert_eq("done", mm._state)
        runner.assert_eq(3, mm._generation, "later reload completed and advanced the generation")
        runner.assert_nil(mm._mod_load_index, "load index settled after the clean later reload")
    end)

    -- ---------------------------------------------------------------------
    -- Shutdown invariant: destroy() never double-unloads after reload
    -- ---------------------------------------------------------------------

    runner.register("hot_reload: destroy after reload unloads current generation only (no double-unload)", function()
        local sb, state = setup()
        local seq = {}
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", seq)) })
        local mm = new_loaded(sb)
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", seq)) })
        mm:request_reload("test")
        mm:update(0.016)  -- teardown: old alpha unloaded exactly once
        tick_to_done(mm)  -- replacement: new alpha loaded
        local unloaded_before = count_tag(seq, ":on_unload")
        runner.assert_eq(1, unloaded_before, "old alpha unloaded exactly once during teardown")
        mm:destroy()
        runner.assert_eq(2, count_tag(seq, ":on_unload"),
            "destroy() unloaded the current generation once; old not double-unloaded")
    end)

    runner.register("hot_reload: destroy after a FAILED reload unloads current generation only", function()
        local sb, state = setup()
        local seq = {}
        stage(state, { "alpha", "beta" }, {
            alpha = mod_file("alpha", recording_mod("alpha", seq, { fail_reload = true })),
            beta = mod_file("beta", recording_mod("beta", seq)),
        })
        local mm = new_loaded(sb)
        mm:request_reload("test")
        mm:update(0.016)  -- teardown (alpha on_reload fails; both unloaded)
        tick_to_done(mm)  -- replacement: alpha+beta reloaded
        runner.assert_eq("done", mm._state)
        clear(seq)
        mm:destroy()
        runner.assert_eq(2, count_tag(seq, ":on_unload"),
            "destroy after failed reload unloads exactly the current two objects")
    end)

    -- -----------------------------------------------------------------
    -- _check_reload trigger-detection seam
    -- -----------------------------------------------------------------

    runner.register("hot_reload: _check_reload exists on the class before any mod runs", function()
        local sb = setup()
        local ModManager = load_driver(sb)  -- class loaded, no :new() yet
        runner.assert_type("function", ModManager._check_reload,
            "_check_reload is defined on the class at module load (before any mod runs)")
    end)

    runner.register("hot_reload: _check_reload returns true only for LEFT Ctrl+LEFT Shift+R", function()
        local sb, state, kstate = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        -- LEFT Ctrl + LEFT Shift + R -> true
        kstate.r = true; kstate.lshift = true; kstate.lctrl = true
        runner.assert_eq(true, mm:_check_reload(), "exact LEFT combo -> true")
        -- R only -> false
        kstate.r = true; kstate.lshift = false; kstate.lctrl = false
        runner.assert_eq(false, mm:_check_reload(), "R alone -> false")
        -- LEFT modifiers without R -> false
        kstate.r = false; kstate.lshift = true; kstate.lctrl = true
        runner.assert_eq(false, mm:_check_reload(), "modifiers without R -> false")
        -- only one LEFT modifier + R -> false
        kstate.r = true; kstate.lshift = true; kstate.lctrl = false
        runner.assert_eq(false, mm:_check_reload(), "one modifier + R -> false")
        -- RIGHT modifiers + R -> false (left-only parity)
        kstate.r = true; kstate.rshift = true; kstate.rctrl = true
        kstate.lshift = false; kstate.lctrl = false
        runner.assert_eq(false, mm:_check_reload(), "RIGHT modifiers + R -> false (left-only)")
    end)

    runner.register("hot_reload: replacing _check_reload to return false suppresses the built-in gesture", function()
        local sb, state, kstate = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm, ModManager = new_loaded_with_class(sb)
        -- Replace on the class to always return false (community suppression).
        ModManager._check_reload = function() return false end
        kstate.r = true; kstate.lshift = true; kstate.lctrl = true
        mm:update(0.016)
        runner.assert_eq(false, mm._reload_requested,
            "a false-returning _check_reload suppresses the request even with keys active")
    end)

    runner.register("hot_reload: _check_reload returning true still routes through request_reload", function()
        local sb, state = setup({ developer_mode = false })
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm, ModManager = new_loaded_with_class(sb)
        -- Force true; request_reload must still enforce developer mode.
        ModManager._check_reload = function() return true end
        mm:update(0.016)
        runner.assert_eq(false, mm._reload_requested,
            "a true result still routes through request_reload (developer mode gates)")
    end)

    runner.register("hot_reload: a throwing _check_reload is contained; mod updates continue", function()
        local sb, state, kstate = setup()
        local seq = {}
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", seq)) })
        local mm, ModManager = new_loaded_with_class(sb)
        ModManager._check_reload = function() error("community override boom") end
        clear(seq)
        local ok = pcall(function() mm:update(0.016) end)
        runner.assert_eq(true, ok, "update must not propagate the throwing override")
        runner.assert_eq(false, mm._reload_requested, "no reload from a throwing override")
        runner.assert_eq(1, count_tag(seq, ":update"),
            "normal mod updates continue after the contained throw")
    end)

    runner.register("hot_reload: _check_reload recovers + single-logs on missing keyboard", function()
        local sb, state = setup()
        sb.Keyboard = nil
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local logged = {}
        sb.__print = function(m) table.insert(logged, m) end
        local mm = new_loaded(sb)
        -- Drive _check_reload directly across multiple calls; it returns false
        -- each time, and the unavailable condition logs exactly once (non-spam).
        local results = {}
        for _ = 1, 3 do
            table.insert(results, mm:_check_reload())
        end
        runner.assert_eq({ false, false, false }, results, "missing keyboard -> false, no throw")
        runner.assert_eq(1, count_log(logged, "shortcut unavailable"),
            "unavailable logged once across three direct checks (non-spamming)")
    end)

    runner.register("hot_reload: 3 reloads do not stack _check_reload (one gesture -> one request)", function()
        local sb, state, kstate = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        -- The method is a single definition on the persistent class; hot reload
        -- does not re-install it (no layering). After 3 reloads, one gesture
        -- still produces exactly one request (request_reload no-stacking enforces).
        for _ = 1, 3 do
            mm:request_reload("test")
            reload_to_done(mm)
        end
        runner.assert_eq(4, mm._generation, "three reloads -> generation 4")
        kstate.r = true; kstate.lshift = true; kstate.lctrl = true
        mm:update(0.016)
        runner.assert_eq(true, mm._reload_in_progress,
            "one gesture after 3 reloads produces one request (entered teardown)")
        runner.assert_eq(false, mm._reload_requested,
            "request consumed in the same frame (no stacking)")
    end)

    runner.register("hot_reload: direct _reload_requested = true legacy path still completes a reload", function()
        local sb, state = setup()
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        -- Legacy: at least one public extension sets the field directly.
        -- Catalog as legacy compatibility; do not remove. update() consumes it.
        mm._reload_requested = true
        mm:update(0.016)  -- teardown frame
        runner.assert_eq(true, mm._reload_in_progress, "legacy direct flag consumed -> teardown")
        tick_to_done(mm)  -- replacement replay
        runner.assert_eq("done", mm._state)
        runner.assert_eq(2, mm._generation, "legacy path completed a reload")
    end)

    runner.register("hot_reload: direct _reload_requested = true MID-pass aborts cleanly (no stale load index)", function()
        -- The legacy direct-flag path can fire while a pass is still open
        -- (the request_reload seam is refused mid-pass, but the raw field is
        -- not). The teardown branch must settle the pass AND clear the load
        -- index so no stale _mod_load_index survives into teardown + anchor.
        local sb, state = setup()
        stage(state, { "alpha", "beta" }, {
            alpha = mod_file("alpha", recording_mod("alpha", {})),
            beta = mod_file("beta", recording_mod("beta", {})),
        })
        local mm = load_driver(sb):new()
        mm._adapter:establish()
        mm:update(0.016)  -- anchor
        mm:update(0.016)  -- alpha's tick: pass open, index = 1, beta pending
        runner.assert_eq(1, mm._mod_load_index)
        runner.assert_eq(false, mm._adapter:is_load_done())

        mm._reload_requested = true
        mm:update(0.016)  -- teardown tick aborts the open pass
        runner.assert_nil(mm._mod_load_index,
            "the mid-pass abort clears the load index (no stale index at teardown)")
        runner.assert_nil(mm._load_phase, "the pass bookkeeping is settled")
        runner.assert_eq(true, mm._reload_in_progress)

        tick_to_done(mm)  -- replacement replay completes
        runner.assert_eq("done", mm._state)
        -- The aborted pass never finalized, so no generation was installed
        -- before the teardown; the replacement installs generation 1.
        runner.assert_eq(1, mm._generation)
        runner.assert_eq("running", mm._mods[1].state)
        runner.assert_eq("running", mm._mods[2].state)
        runner.assert_nil(mm._mod_load_index)
    end)

    -- -----------------------------------------------------------------
    -- Startup trace diagnostics: the reload pass-begin line names its generation
    -- -----------------------------------------------------------------

    runner.register("hot_reload: reload pass-begin TRACE names the target generation", function()
        local logged = {}
        local sb, state = setup({ print = function(m) table.insert(logged, m) end })
        sb.Mods._relay._trace_enabled = true
        sb.FRAME_INDEX = 12
        stage(state, { "alpha" }, { alpha = mod_file("alpha", recording_mod("alpha", {})) })
        local mm = new_loaded(sb)
        runner.assert_eq(1, count_log(logged, "load pass begin (initial) tick=0 frame=12"),
            "the initial pass-begin line is stamped")
        mm:request_reload("test")
        mm:update(0.016)  -- teardown frame (no load pass)
        runner.assert_eq(1, count_log(logged, "load pass begin"),
            "the teardown frame runs no load pass")
        mm:update(0.016)  -- replacement frame
        runner.assert_eq(1, count_log(logged, "load pass begin (reload, generation 2)"),
            "the replacement pass names its target generation")
        runner.assert_eq(2, count_log(logged, "load pass begin"),
            "exactly two pass-begin lines total (initial + one reload)")
    end)
end
