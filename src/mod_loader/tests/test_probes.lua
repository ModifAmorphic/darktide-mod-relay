-- test_probes.lua — structural validation of the live diagnostic probes.
--
-- The probes under tests/probes/ are manual live diagnostics: they are NOT
-- executed by this harness (they only run when staged into the real game).
-- This test does NOT run any probe. It asserts the on-disk STRUCTURE of each
-- scenario bundle and a small set of key markers, so a broken rename, a
-- missing replacement file, or a probe that drifts from its documented
-- contract is caught here rather than at live-staging time.
--
-- What this test checks:
--   * every expected probe file exists at its categorized path;
--   * each .mod compiles (loadstring, no execution) — catches syntax errors
--     without running the probe or polluting _G;
--   * each probe contains the distinctive console prefix and contract
--     identifiers its README documents; and
--   * each scenario's mods.lst + replacement .lst + mode files contain the
--     documented entries/values.
--
-- What this test does NOT check: probe behavior under the real engine. That
-- is the live-acceptance pass described in each scenario README.

local mock = require("mock")

return function(runner)
    -- tests/probes/ is a sibling of this test file's directory.
    local probes_dir = mock.module_dir .. "tests/probes/"

    local function read(rel)
        local f = io.open(probes_dir .. rel, "r")
        if not f then
            return nil
        end
        local data = f:read("*all")
        f:close()
        return data
    end

    local function assert_present(rel)
        local data = read(rel)
        runner.assert_not_nil(data, "probe file missing: " .. rel)
        return data
    end

    -- Compile-check a .mod via loadstring WITHOUT executing it. Returns the
    -- source string on success; fails the test on missing/unparseable files.
    local function assert_compilable(rel)
        local src = assert_present(rel)
        local fn, err = loadstring(src, rel)
        runner.assert_not_nil(fn, rel .. " did not compile: " .. tostring(err))
        return src
    end

    local function assert_contains(src, marker, rel)
        runner.assert_not_nil(
            (type(src) == "string" and src:find(marker, 1, true)) or nil,
            rel .. " missing marker " .. tostring(marker))
    end

    local function assert_not_contains(src, marker, rel)
        if type(src) == "string" and src:find(marker, 1, true) then
            runner.fail(rel .. " must not contain " .. tostring(marker))
        end
    end

    -- Assert a mods.lst-shaped file lists exactly the given entries (in order,
    -- ignoring blank and `--` comment lines, matching the loader's reader).
    local function assert_lst(rel, expected, label)
        local src = assert_present(rel)
        local seen = {}
        for line in src:gmatch("[^\r\n]+") do
            local trimmed = line:gsub("^%s*(.-)%s*$", "%1")
            if trimmed ~= "" and trimmed:sub(1, 2) ~= "--" then
                seen[#seen + 1] = trimmed
            end
        end
        runner.assert_eq(expected, seen, label or rel)
    end

    -- -------------------------------------------------------------------
    -- observational/ — every scenario ships the uniform complete-bundle
    -- shape (README.md + mods/mods.lst + mods/<probe>/<probe>.mod). The
    -- legacy flat layout (a single <probe>/<probe>.mod with no mods.lst,
    -- staged by copying a leaf folder and merging a mods.lst line) is gone.
    -- -------------------------------------------------------------------
    runner.register("probes: observational scenarios are complete bundles (uniform shape)", function()
        local scenarios = {
            {
                dir = "observational/shutdown_probe",
                probe = "shutdown_probe",
                mod_rel = "observational/shutdown_probe/mods/shutdown_probe/shutdown_probe.mod",
                old_rel = "observational/shutdown_probe/shutdown_probe.mod",
                readme_behavior = { "[SHUTDOWN_PROBE]", "on_game_state_changed" },
            },
            {
                dir = "observational/reload_seam_probe",
                probe = "reload_seam_probe",
                mod_rel = "observational/reload_seam_probe/mods/reload_seam_probe/reload_seam_probe.mod",
                old_rel = "observational/reload_seam_probe/reload_seam_probe.mod",
                readme_behavior = { "_check_reload" },
            },
            {
                dir = "observational/lua_logs_probe",
                probe = "lua_logs_probe",
                mod_rel = "observational/lua_logs_probe/mods/lua_logs_probe/lua_logs_probe.mod",
                old_rel = "observational/lua_logs_probe/lua_logs_probe.mod",
                readme_behavior = { "[LUA_LOGS_PROBE]", "--lua-logs" },
            },
        }
        for _, s in ipairs(scenarios) do
            -- mods.lst lists exactly the one probe (authoritative order).
            assert_lst(s.dir .. "/mods/mods.lst", { s.probe },
                s.dir .. "/mods/mods.lst must list exactly its probe")
            -- .mod compiles at the new bundled path.
            assert_compilable(s.mod_rel)
            -- The old flat layout is gone.
            runner.assert_nil(read(s.old_rel),
                "old flat path " .. s.old_rel .. " must be gone (moved into mods/<probe>/)")
            -- Scenario README exists and documents direct --mod-path + behavior.
            local readme = assert_present(s.dir .. "/README.md")
            assert_contains(readme, "--mod-path", s.dir .. " README (direct --mod-path)")
            for _, m in ipairs(s.readme_behavior) do
                assert_contains(readme, m, s.dir .. " README (behavior: " .. m .. ")")
            end
        end
    end)

    -- Probe-specific content markers (behavior unchanged; paths moved).
    runner.register("probes: observational shutdown_probe + reload_seam_probe content markers", function()
        local shutdown = assert_compilable("observational/shutdown_probe/mods/shutdown_probe/shutdown_probe.mod")
        assert_contains(shutdown, "[SHUTDOWN_PROBE]", "shutdown_probe")
        assert_contains(shutdown, "on_game_state_changed", "shutdown_probe")
        assert_contains(shutdown, "shutdown_probe/shutdown_probe.log", "shutdown_probe")
        -- Logging robustness matches the new probes: protected print, protected
        -- Mods -> lua -> io -> open chain, and safe_append (close always runs).
        assert_contains(shutdown, "_pcall(_print", "shutdown_probe (protected print)")
        assert_contains(shutdown, "_type(op) ~= \"function\"", "shutdown_probe (open type-guard)")
        assert_contains(shutdown, "safe_append", "shutdown_probe (best-effort close helper)")

        local reload = assert_compilable("observational/reload_seam_probe/mods/reload_seam_probe/reload_seam_probe.mod")
        assert_contains(reload, "_check_reload", "reload_seam_probe")
        assert_contains(reload, "CLASS.ModManager", "reload_seam_probe")
    end)

    -- -------------------------------------------------------------------
    -- observational/lua_logs_probe: the Lua print-tee observational probe.
    -- Structural-only: compile + distinctive case/contract markers. The probe
    -- is NOT executed here (it only runs staged in the real game).
    -- -------------------------------------------------------------------
    runner.register("probes: observational/lua_logs_probe structure + markers", function()
        local probe = assert_compilable("observational/lua_logs_probe/mods/lua_logs_probe/lua_logs_probe.mod")
        -- Distinctive prefix + one marker per documented case.
        assert_contains(probe, "[LUA_LOGS_PROBE]", "lua_logs_probe (prefix)")
        assert_contains(probe, "case=simple_print", "lua_logs_probe (simple_print case)")
        assert_contains(probe, "case=simple_dprint", "lua_logs_probe (simple_dprint case)")
        assert_contains(probe, "case=multi_args", "lua_logs_probe (multi_args case)")
        assert_contains(probe, "case=multiline_crlf", "lua_logs_probe (multiline_crlf case)")
        assert_contains(probe, "case=percent_fmt", "lua_logs_probe (percent_fmt case)")
        assert_contains(probe, "case=control_bytes", "lua_logs_probe (control_bytes case)")
        assert_contains(probe, "case=over_budget", "lua_logs_probe (over_budget case)")
        -- Exercises BOTH wrapped surfaces (global print + __print); __print is
        -- probed separately and degrades to a clear marker when unavailable.
        assert_contains(probe, "local _print    = print", "lua_logs_probe (print surface)")
        assert_contains(probe, "__print", "lua_logs_probe (__print surface)")
        -- Control bytes are CONSTRUCTED (string.char), never raw in source, and
        -- the over-budget case exceeds the 4096-byte native input budget.
        assert_contains(probe, "string.char", "lua_logs_probe (safe control-byte construction)")
        assert_contains(probe, "string.rep", "lua_logs_probe (over-budget payload construction)")
        -- Process-lifetime load index (survives hot reload via _G) + rooted
        -- scenario log path (operator convenience).
        assert_contains(probe, "_RELAY_LUA_LOGS_PROBE_LOAD", "lua_logs_probe (load index global)")
        assert_contains(probe, "lua_logs_probe/lua_logs_probe.log", "lua_logs_probe (scenario log)")
        -- The probe is read-only and must NOT touch Relay's private sink/temp
        -- global directly, nor any forbidden community logging surface.
        assert_not_contains(probe, "__mod_relay_lua_log_sink", "lua_logs_probe (no private sink)")
        assert_not_contains(probe, "Mods.message", "lua_logs_probe (no community surface)")
        -- Every case is failure-contained (an unavailable surface records a
        -- clear marker instead of crashing the game).
        assert_contains(probe, "status=unavailable", "lua_logs_probe (contained failure marker)")
        assert_contains(probe, "_pcall(body)", "lua_logs_probe (per-case containment)")

        -- README documents the complete-bundle staging (no legacy Shape-A
        -- copy/merge), launch variants, expected evidence, the acceptance
        -- matrix, the stock-DMF black-box caveat, and cleanup.
        local readme = assert_present("observational/lua_logs_probe/README.md")
        assert_contains(readme, "[LUA_LOGS_PROBE]", "lua_logs_probe README (prefix)")
        assert_contains(readme, "--mod-path", "lua_logs_probe README (direct --mod-path)")
        assert_contains(readme, "complete bundle", "lua_logs_probe README (uniform staging shape)")
        assert_not_contains(readme, "Shape A", "lua_logs_probe README (legacy shape gone)")
        assert_not_contains(readme, "Add (or merge)", "lua_logs_probe README (no list-merge step)")
        assert_contains(readme, "--lua-logs", "lua_logs_probe README (CLI variant)")
        assert_contains(readme, "RELAY_LUA_LOGS=1", "lua_logs_probe README (env variant)")
        assert_contains(readme, "Default off", "lua_logs_probe README (matrix: default off)")
        assert_contains(readme, "CLI on", "lua_logs_probe README (matrix: CLI on)")
        assert_contains(readme, "Env on", "lua_logs_probe README (matrix: env on)")
        assert_contains(readme, "--log-level warn", "lua_logs_probe README (matrix: log-level gate)")
        assert_contains(readme, "No stacking", "lua_logs_probe README (matrix: no stacking)")
        assert_contains(readme, "truncation marker", "lua_logs_probe README (matrix: truncation)")
        assert_contains(readme, "Vanilla", "lua_logs_probe README (matrix: vanilla)")
        assert_contains(readme, "Coverage is", "lua_logs_probe README (coverage-not-guaranteed)")
        assert_contains(readme, "black-box", "lua_logs_probe README (DMF black-box caveat)")
        assert_contains(readme, "Cleanup", "lua_logs_probe README (cleanup section)")
    end)

    -- -------------------------------------------------------------------
    -- metadata/crashify scenario bundle.
    -- -------------------------------------------------------------------
    runner.register("probes: metadata/crashify bundle structure + markers", function()
        assert_lst("metadata/crashify/mods/mods.lst",
            { "crashify_alpha", "crashify_beta", "crashify_probe" },
            "crashify mods.lst")
        -- Replacement lst for the stale-key reload (alpha removed; probe last).
        assert_lst("metadata/crashify/mods/mods-without-alpha.lst",
            { "crashify_beta", "crashify_probe" },
            "crashify mods-without-alpha.lst")

        local alpha = assert_compilable("metadata/crashify/mods/crashify_alpha/crashify_alpha.mod")
        assert_contains(alpha, "[CRASHIFY_ALPHA]", "crashify_alpha")
        -- Nil-return descriptor: the .mod returns a descriptor table whose
        -- `run` function returns nothing (DMF-driven). The descriptor itself
        -- is `return { run = function() ... end }`; the nil-return contract is
        -- marked in the probe's own log text and verified at live time.
        assert_contains(alpha, "nil-return", "crashify_alpha")

        local beta = assert_compilable("metadata/crashify/mods/crashify_beta/crashify_beta.mod")
        assert_contains(beta, "[CRASHIFY_BETA]", "crashify_beta")
        assert_contains(beta, "nil-return", "crashify_beta")

        local probe = assert_compilable("metadata/crashify/mods/crashify_probe/crashify_probe.mod")
        assert_contains(probe, "[CRASHIFY_PROBE]", "crashify_probe")
        -- The three Crashify contract identifiers the probe feature-detects.
        assert_contains(probe, "print_property", "crashify_probe")
        assert_contains(probe, "remove_print_property", "crashify_probe")
        assert_contains(probe, "get_print_property", "crashify_probe")
        -- The getter LOOKUP must be pcall-protected (a throwing __index on the
        -- Crashify table must not break the probe), not a bare assignment.
        -- "return c.get_print_property" only appears inside the pcall-wrapped
        -- lookup; the buggy bare form was "local getter = c.get_print_property".
        assert_contains(probe, "return c.get_print_property",
            "crashify_probe (protected getter lookup)")
        -- The four read-back keys.
        assert_contains(probe, "ModRelay:Version", "crashify_probe")
        assert_contains(probe, "Mod:crashify_alpha", "crashify_probe")
        assert_contains(probe, "Mod:crashify_beta", "crashify_probe")
        assert_contains(probe, "Mod:crashify_probe", "crashify_probe")
        -- Process-global run counter.
        assert_contains(probe, "_RELAY_CRASHIFY_PROBE_RUN", "crashify_probe")
        -- Scenario log rooted under the probe folder.
        assert_contains(probe, "crashify_probe/crashify_probe.log", "crashify_probe")
        -- The probe must be read-only: it must NOT publish or remove.
        assert_not_contains(probe, "Crashify.print_property(", "crashify_probe (read-only)")
        assert_not_contains(probe, "Crashify.remove_print_property(", "crashify_probe (read-only)")
    end)

    -- -------------------------------------------------------------------
    -- failure_injection/standalone scenario bundle.
    -- -------------------------------------------------------------------
    runner.register("probes: failure_injection/standalone bundle structure + markers", function()
        assert_lst("failure_injection/standalone/mods/mods.lst",
            { "standalone_failure_probe", "healthy_sibling_probe" },
            "standalone mods.lst")

        local mode_fail = assert_present("failure_injection/standalone/mods/standalone_failure_probe/mode.txt")
        assert_contains(mode_fail, "fail", "standalone mode.txt")
        local mode_healthy = assert_present(
            "failure_injection/standalone/mods/standalone_failure_probe/mode-healthy.txt")
        assert_contains(mode_healthy, "healthy", "standalone mode-healthy.txt")

        local probe = assert_compilable(
            "failure_injection/standalone/mods/standalone_failure_probe/standalone_failure_probe.mod")
        assert_contains(probe, "[STANDALONE_FAILURE]", "standalone_failure_probe")
        assert_contains(probe, "standalone_failure_probe/mode.txt", "standalone_failure_probe")
        assert_contains(probe, "standalone_failure_probe/standalone_failure_probe.log",
            "standalone_failure_probe")
        -- Must raise a neutral Relay-owned error in fail mode.
        assert_contains(probe, "_RELAY_STANDALONE_FAIL_UPDATES", "standalone_failure_probe")
        assert_contains(probe, "_RELAY_STANDALONE_FAIL_UNLOADS", "standalone_failure_probe")
        assert_contains(probe, "injected update failure", "standalone_failure_probe")
        -- Must not reference forbidden community surfaces.
        assert_not_contains(probe, "Mods.message", "standalone_failure_probe")
        assert_not_contains(probe, "Mods.lua.debug", "standalone_failure_probe")

        local sibling = assert_compilable(
            "failure_injection/standalone/mods/healthy_sibling_probe/healthy_sibling_probe.mod")
        assert_contains(sibling, "[HEALTHY_SIBLING]", "healthy_sibling_probe")
        assert_contains(sibling, "healthy_sibling_probe/healthy_sibling_probe.log",
            "healthy_sibling_probe")
        assert_not_contains(sibling, "Mods.message", "healthy_sibling_probe")
    end)

    -- -------------------------------------------------------------------
    -- failure_injection/framework_boundary scenario bundle.
    -- -------------------------------------------------------------------
    runner.register("probes: failure_injection/framework_boundary bundle structure + markers", function()
        assert_lst("failure_injection/framework_boundary/mods/mods.lst",
            { "framework_prior_probe", "dmf", "framework_later_probe" },
            "framework_boundary mods.lst (dmf must be the middle entry)")

        local mode_fail = assert_present("failure_injection/framework_boundary/mods/dmf/mode.txt")
        assert_contains(mode_fail, "fail", "framework_boundary dmf mode.txt")
        local mode_healthy = assert_present(
            "failure_injection/framework_boundary/mods/dmf/mode-healthy.txt")
        assert_contains(mode_healthy, "healthy", "framework_boundary dmf mode-healthy.txt")

        local prior = assert_compilable(
            "failure_injection/framework_boundary/mods/framework_prior_probe/framework_prior_probe.mod")
        assert_contains(prior, "[FB_PRIOR]", "framework_prior_probe")
        assert_contains(prior, "framework_boundary.log", "framework_prior_probe (shared log)")
        assert_contains(prior, "_RELAY_FB_PRIOR_RUN", "framework_prior_probe")

        local dmf = assert_compilable("failure_injection/framework_boundary/mods/dmf/dmf.mod")
        assert_contains(dmf, "[FB_DMF]", "synthetic dmf probe")
        -- Must be clearly labeled synthetic, not stock DMF.
        assert_contains(dmf, "SYNTHETIC", "synthetic dmf probe label")
        assert_contains(dmf, "framework_boundary.log", "synthetic dmf probe (shared log)")
        assert_contains(dmf, "dmf/mode.txt", "synthetic dmf probe mode file")
        assert_contains(dmf, "_RELAY_FB_DMF_INIT", "synthetic dmf probe counters")
        assert_contains(dmf, "injected init failure", "synthetic dmf probe error")
        -- Must not mutate engine/class state or override loader seams. These
        -- precise checks replace a fragile bare-word "hook" search (the word
        -- legitimately appears in safety comments).
        assert_not_contains(dmf, "Mods.message", "synthetic dmf probe")
        assert_not_contains(dmf, "Mods.lua.debug", "synthetic dmf probe")
        assert_not_contains(dmf, "CLASS.", "synthetic dmf probe (no class-table mutation)")
        assert_not_contains(dmf, "_check_reload", "synthetic dmf probe (no seam override)")

        local later = assert_compilable(
            "failure_injection/framework_boundary/mods/framework_later_probe/framework_later_probe.mod")
        assert_contains(later, "[FB_LATER]", "framework_later_probe")
        assert_contains(later, "framework_boundary.log", "framework_later_probe (shared log)")
        assert_contains(later, "_RELAY_FB_LATER_RUN", "framework_later_probe")
    end)

    -- -------------------------------------------------------------------
    -- Top-level index README documents exactly ONE staging shape (the uniform
    -- complete-bundle contract) and every category + scenario.
    -- -------------------------------------------------------------------
    runner.register("probes: top-level README indexes one uniform complete-bundle shape", function()
        local index = assert_present("README.md")
        assert_contains(index, "observational", "probes index")
        assert_contains(index, "metadata", "probes index")
        assert_contains(index, "failure_injection", "probes index")
        -- Exactly ONE staging shape: the uniform complete-bundle contract.
        assert_contains(index, "complete scenario bundle",
            "probes index (uniform complete-bundle shape)")
        assert_contains(index, "--mod-path", "probes index (direct launch)")
        -- The legacy two-shape convention and single-folder/list-merge staging
        -- instructions must be gone.
        assert_not_contains(index, "Shape A", "probes index (legacy Shape A gone)")
        assert_not_contains(index, "Shape B", "probes index (legacy Shape B gone)")
        assert_not_contains(index, "Add (or merge)", "probes index (no list-merge step)")
        -- Accurate framing: probes are not EXECUTED by the harness, but
        -- test_probes.lua does structurally validate them (compile + markers).
        assert_contains(index, "not executed", "probes index (accurate harness framing)")
        assert_contains(index, "offline LuaJIT test harness", "probes index")
        assert_contains(index, "test_probes.lua", "probes index (structural validation noted)")
        assert_contains(index, "part of the shipped runtime", "probes index")
        -- The lua_logs_probe observational probe is indexed too, and the index
        -- no longer makes the now-stale blanket claim that probe/loader lines
        -- never reach relay.log (the claim is conditional on --lua-logs).
        assert_contains(index, "lua_logs_probe", "probes index (lua_logs_probe listed)")
        assert_contains(index, "[LUA_LOGS_PROBE]", "probes index (lua_logs_probe prefix)")
        assert_contains(index, "--lua-logs", "probes index (conditional relay.log claim)")
        -- Links to each scenario README (observational scenarios now ship one too).
        assert_contains(index, "observational/shutdown_probe/README.md",
            "probes index shutdown_probe link")
        assert_contains(index, "observational/reload_seam_probe/README.md",
            "probes index reload_seam_probe link")
        assert_contains(index, "observational/lua_logs_probe/README.md",
            "probes index lua_logs_probe link")
        assert_contains(index, "metadata/crashify/README.md", "probes index crashify link")
        assert_contains(index, "failure_injection/standalone/README.md", "probes index standalone link")
        assert_contains(index, "failure_injection/framework_boundary/README.md",
            "probes index framework_boundary link")
    end)
end
