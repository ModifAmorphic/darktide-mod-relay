-- runner.lua — mod loader offline LuaJIT test harness.
--
-- Test framework (register/run + assert_* helpers) + the entry point. Mirrors
-- the style of src/tests/test_runner.c: tests register by name, run in
-- order, results print PASS/FAIL per test + a summary line, and the process
-- exits non-zero on any failure.
--
-- Usage:  luajit src/mod_loader/tests/runner.lua
--
-- Each test_*.lua is a module that returns a function taking the runner; it
-- registers its tests via runner.register inside that function.

local dirname = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
package.path = dirname .. "?.lua;" .. package.path

local M = {}

local tests = {}
local current_failed = false

function M.register(name, fn)
    tests[#tests + 1] = { name = name, fn = fn }
end

-- Mark the current test as failed (recorded) and abort it (raised). The pcall
-- in run() catches the raise; we record via current_failed so a non-assertion
-- error (test code bug) also reports as FAIL rather than crashing the harness.
function M.fail(msg)
    current_failed = true
    error(msg or "assertion failed", 2)
end

local function deep_eq(a, b)
    if a == b then return true end  -- reference equality (also covers primitives)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

function M.assert_eq(expected, actual, msg)
    if not deep_eq(expected, actual) then
        M.fail(msg or ("expected " .. tostring(expected) .. ", got " .. tostring(actual)))
    end
end

function M.assert_truthy(val, msg)
    if not val then
        M.fail(msg or "expected truthy, got " .. tostring(val))
    end
end

function M.assert_not_nil(val, msg)
    if val == nil then
        M.fail(msg or "expected non-nil")
    end
end

function M.assert_nil(val, msg)
    if val ~= nil then
        M.fail(msg or "expected nil, got " .. tostring(val))
    end
end

function M.assert_type(tp, val, msg)
    if type(val) ~= tp then
        M.fail(msg or ("expected type " .. tp .. ", got " .. type(val)))
    end
end

-- Run all registered tests. Returns 0 on full pass, 1 on any failure.
function M.run()
    local passed, failed = 0, 0
    for _, t in ipairs(tests) do
        current_failed = false
        local ok, err = pcall(t.fn)
        if ok and not current_failed then
            passed = passed + 1
            print("  PASS: " .. t.name)
        else
            failed = failed + 1
            local where = (not ok) and (" (error: " .. tostring(err) .. ")") or ""
            print("  FAIL: " .. t.name .. where)
        end
    end
    print(string.format("\n--- %d/%d tests passed ---", passed, #tests))
    return (failed > 0) and 1 or 0
end

-- Load + register tests from each test module. Each returns a function that
-- takes the runner and registers its tests.
local test_files = {
    "test_path",
    "test_file",
    "test_class_registry",
    "test_require_bridge",
    "test_lifecycle",
    "test_mod_manager",
    "test_dmf_adapter",
    "test_hot_reload",
    "test_loader_hardening",
    "test_entry",
    "test_lua_logs",
    "test_negative",
    "test_probes",
}
for _, name in ipairs(test_files) do
    require(name)(M)
end

os.exit(M.run(), true)
