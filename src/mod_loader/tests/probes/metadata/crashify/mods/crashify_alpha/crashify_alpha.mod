-- crashify_alpha.mod -- manual live diagnostic (not a harness test; not shipped).
--
-- One of two plainly-named scratch entries that earn a `Mod:crashify_alpha`
-- crash property. Returns nil from run() so the loader treats it as a
-- DMF-driven registration side effect (no outer object, no Relay-driven
-- callbacks). It exists only to:
--   * log that its run() executed (a visible "I loaded" marker); and
--   * be a stable Crashify key the crashify_probe can read back.
--
-- Install: this folder ships as part of the metadata/crashify scenario bundle.
-- Copy mods/crashify_alpha/ into <mod_path>/mods/crashify_alpha/ and list
-- `crashify_alpha` in <mod_path>/mods/mods.lst (the bundle's mods.lst already
-- does). No file output; console prefix `[CRASHIFY_ALPHA]`.
--
-- This probe is intentionally inert: it touches no engine state, installs no
-- hooks, and reads nothing from disk. It must never become a failure source.

local _print = print or __print or function() end
local _pcall = pcall

return {
    run = function()
        _pcall(_print, "[CRASHIFY_ALPHA] run executed (nil-return descriptor)")
    end,
}
