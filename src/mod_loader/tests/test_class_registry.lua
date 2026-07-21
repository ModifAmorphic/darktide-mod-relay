-- test_class_registry.lua — class wrapping + CLASS registry (src/mod_loader/class_registry.lua).
--
-- Asserts:
--   - install is idempotent and returns not-ready while `class` is absent/non-function
--   - once installed, every class() result is stored in CLASS[name]
--   - super/varargs forwarded exactly; original result returned verbatim
--   - unresolved CLASS[name] returns the NAME STRING sentinel (official DMF's
--     generic_hook string/table validator accepts it); rawget returns nil so
--     lifecycle readiness treats unresolved classes as absent
--   - each class() result is ALSO globalized to _G[name] (mod-compatibility
--     contract — mods in the wild cache class globals like _G.Promise); an
--     explicit _G[name] set by other code is preserved (rawget-guarded, not
--     clobbered)
--   - retire_class(name) clears _G[name] (the sole retire path for the
--     _G[class_name] surface); CLASS[name] is retained, non-string names are
--     no-ops, unregistered names are safe no-ops

local mock = require("mock")

return function(runner)
    -- Load class_registry into a sandbox. The test sets up `class` + CLASS as
    -- needed before/after loading.
    local function setup(class_fn)
        local sb = mock.new_sandbox()
        sb.Mods = {}
        sb.__print = function() end
        if class_fn ~= nil then
            sb.class = class_fn
        end
        mock.run_module("class_registry", sb)
        return sb
    end

    -- A fake engine class() that records calls + returns a fresh table per name.
    local function fake_class()
        local calls = {}
        local function class_fn(name, ...)
            table.insert(calls, { name = name, supers = { ... } })
            local meta = { name = name }
            meta.__index = meta
            return meta
        end
        return class_fn, calls
    end

    -- ---------------------------------------------------------------------
    -- Readiness + idempotency
    -- ---------------------------------------------------------------------

    runner.register("class_registry: not-ready (false) while class is absent", function()
        local sb = setup(nil)  -- no class global
        runner.assert_eq(false, sb.Mods.install_class_registry(),
            "must return false when class is absent")
        runner.assert_nil(sb._G.class, "must not mutate _G.class when not-ready")
    end)

    runner.register("class_registry: not-ready while class is non-function (table)", function()
        local sb = setup({})  -- class is a table, not a function
        runner.assert_eq(false, sb.Mods.install_class_registry(),
            "must return false when class is a non-function")
    end)

    runner.register("class_registry: install is idempotent", function()
        local cf, calls = fake_class()
        local sb = setup(cf)
        runner.assert_eq(true, sb.Mods.install_class_registry())
        runner.assert_eq(true, sb.Mods.install_class_registry(),
            "second install is a no-op returning true")
        -- Captured original is the one passed in; wrapping happens once.
        sb.class("Foo")
        sb.class("Bar")
        runner.assert_eq(2, #calls, "class calls forward to the original")
    end)

    -- ---------------------------------------------------------------------
    -- CLASS population + forwarding
    -- ---------------------------------------------------------------------

    runner.register("class_registry: class() results land in CLASS[name]", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        local foo = sb.class("Foo")
        local bar = sb.class("Bar")
        runner.assert_eq(foo, sb.CLASS.Foo, "Foo result stored in CLASS")
        runner.assert_eq(bar, sb.CLASS.Bar, "Bar result stored in CLASS")
    end)

    runner.register("class_registry: wrapper forwards varargs (super classes)", function()
        local seen_supers = nil
        local function class_fn(name, ...)
            seen_supers = { ... }
            return { name = name }
        end
        local sb = setup(class_fn)
        sb.Mods.install_class_registry()
        sb.class("Widget", "Base", "Mixin")
        runner.assert_eq({ "Base", "Mixin" }, seen_supers,
            "super class varargs must be forwarded exactly")
    end)

    runner.register("class_registry: wrapper returns the original result verbatim", function()
        local sentinel = { marker = true }
        local function class_fn() return sentinel end
        local sb = setup(class_fn)
        sb.Mods.install_class_registry()
        local r = sb.class("Whatever")
        runner.assert_eq(sentinel, r, "wrapper must return exactly what the original returned")
    end)

    runner.register("class_registry: non-string class name does not corrupt CLASS", function()
        local function class_fn() return { x = 1 } end
        local sb = setup(class_fn)
        sb.Mods.install_class_registry()
        local r = sb.class(123)  -- weird but defensive: name not a string
        runner.assert_truthy(r ~= nil)
        -- CLASS must not gain a stored [123] entry from a non-string name. The
        -- __index sentinel returns the key for any missing key, so assert via
        -- rawget (which bypasses the metatable) that nothing was stored.
        runner.assert_nil(rawget(sb.CLASS, 123),
            "non-string class names must not be stored in CLASS")
    end)

    -- ---------------------------------------------------------------------
    -- Unresolved-class string sentinel (official DMF compatibility)
    -- ---------------------------------------------------------------------
    --
    -- Missing CLASS[name] returns the NAME STRING so official DMF's
    -- generic_hook string/table validator accepts dmf:hook_safe(CLASS.X, ...)
    -- issued before the class exists and queues it as a delayed hook. rawget
    -- still returns nil for unresolved classes (the lifecycle's readiness
    -- checks rely on this).

    runner.register("class_registry: unresolved CLASS[name] returns the name string sentinel", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        -- Before registration, the sentinel is the name string.
        runner.assert_eq("InputService", sb.CLASS.InputService,
            "unresolved CLASS.InputService must return the name string")
        runner.assert_eq("StateGame", sb.CLASS.StateGame)
        runner.assert_eq("Also.Missing", sb.CLASS["Also.Missing"],
            "dotted-style unresolved key returns the name string too")
    end)

    runner.register("class_registry: the sentinel value is a string (acceptable to DMF's string/table validator)", function()
        -- A synthetic DMF-style delayed-hook validator accepts string OR table.
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        local function dmf_validate_obj(obj)
            local t = type(obj)
            return t == "string" or t == "table"
        end
        runner.assert_eq(true, dmf_validate_obj(sb.CLASS.InputService),
            "the unresolved sentinel must pass DMF's string/table obj check (not nil)")
        runner.assert_eq("string", type(sb.CLASS.InputService))
    end)

    runner.register("class_registry: after class(name), CLASS[name] is the returned table (not the sentinel)", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        runner.assert_eq("InputService", sb.CLASS.InputService, "sentinel before registration")
        local cls = sb.class("InputService")
        runner.assert_eq(cls, sb.CLASS.InputService,
            "after registration, CLASS.InputService is the real class table")
        runner.assert_eq("table", type(sb.CLASS.InputService),
            "type is now table, not the string sentinel")
    end)

    runner.register("class_registry: rawget(CLASS, unresolved) is nil (lifecycle readiness treats unresolved as absent)", function()
        -- The lifecycle's readiness checks use rawget, which bypasses the
        -- __index sentinel. An unresolved class must be nil under rawget so
        -- the bootstrap does not mistake the sentinel for a real class.
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        runner.assert_nil(rawget(sb.CLASS, "StateGame"),
            "rawget must return nil for an unresolved class (readiness = absent)")
        runner.assert_eq("StateGame", sb.CLASS.StateGame,
            "but CLASS.StateGame (indexed) returns the sentinel string")
        -- After registration, rawget returns the real table.
        local cls = sb.class("StateGame")
        runner.assert_eq(cls, rawget(sb.CLASS, "StateGame"),
            "rawget returns the real class after registration")
    end)

    -- ---------------------------------------------------------------------
    -- Community-contract globalization to _G[name]
    -- ---------------------------------------------------------------------
    --
    -- Each class() result is mirrored to _G[name] (when not already set) so
    -- mods that cache the global (e.g. local Promise = Promise at file scope,
    -- then Promise.delay(...)) work — matching what mods in the wild require.
    -- The unresolved-class sentinel is a READ-side concern only — it never
    -- writes _G, so an unregistered name has no _G entry.

    runner.register("class_registry: class('Foo') registers CLASS.Foo AND globalizes _G.Foo", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        local result = sb.class("Foo")
        runner.assert_eq(result, sb.CLASS.Foo, "CLASS.Foo is the registered class")
        runner.assert_eq(result, sb._G.Foo, "_G.Foo is also published (community contract)")
        runner.assert_not_nil(sb._G.Foo, "_G.Foo must not be nil")
    end)

    runner.register("class_registry: unresolved sentinel does NOT create a _G entry (read-side only)", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        -- Before registration: CLASS.Missing is the sentinel string, but _G
        -- must NOT have a Missing entry (the sentinel is a read-side concern).
        runner.assert_eq("Missing", sb.CLASS.Missing, "sentinel before registration")
        runner.assert_nil(sb._G.Missing,
            "the sentinel must NOT create a _G entry")
    end)

    runner.register("class_registry: explicit _G assignments by other code are preserved", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        -- Some other code explicitly assigns a global (the engine/DMF does this
        -- for some classes). Our wrapper must not touch such assignments.
        sb._G.MyExplicit = "engine-set"
        sb.class("MyExplicit")
        runner.assert_eq("engine-set", sb._G.MyExplicit,
            "explicit _G assignments must not be overwritten by the wrapper")
        runner.assert_not_nil(sb.CLASS.MyExplicit,
            "CLASS still records the class result")
    end)

    -- ---------------------------------------------------------------------
    -- retire_class — sole owner of the _G[class_name] clear surface
    -- ---------------------------------------------------------------------
    --
    -- class_registry owns BOTH directions of _G[class_name]. retire_class is the
    -- single clear path; dmf_adapter (and any consumer) routes class-result
    -- retirement through it. CLASS[name] is retained — only the _G mirror clears.

    runner.register("class_registry: retire_class(name) clears _G[name]", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        local result = sb.class("Foo")
        runner.assert_eq(result, sb._G.Foo, "sanity: _G.Foo set after class('Foo')")
        sb.Mods.retire_class("Foo")
        runner.assert_nil(sb._G.Foo, "retire_class must clear _G.Foo")
    end)

    runner.register("class_registry: retire_class does NOT clear CLASS[name]", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        local result = sb.class("Foo")
        runner.assert_eq(result, sb.CLASS.Foo, "sanity: CLASS.Foo set")
        sb.Mods.retire_class("Foo")
        runner.assert_eq(result, sb.CLASS.Foo,
            "CLASS.Foo survives retire_class (new class() overwrites CLASS normally)")
    end)

    runner.register("class_registry: retire_class is a no-op for non-string names", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        sb._G.Preexisting = "kept"
        -- nil / number / table must all be safe no-ops; _G unchanged.
        sb.Mods.retire_class(nil)
        sb.Mods.retire_class(123)
        sb.Mods.retire_class({})
        runner.assert_eq("kept", sb._G.Preexisting,
            "non-string retire must not pollute _G")
    end)

    runner.register("class_registry: retire_class on an unregistered name is a safe no-op", function()
        local cf = fake_class()
        local sb = setup(cf)
        sb.Mods.install_class_registry()
        -- No throw, no pollution: clearing a non-existent global is a no-op.
        sb.Mods.retire_class("NeverRegistered")
        runner.assert_nil(sb._G.NeverRegistered,
            "retire of an unregistered name leaves _G clean")
    end)
end
