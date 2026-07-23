-- crashify_beta.mod -- manual live diagnostic (not a harness test; not shipped).
--
-- The second plainly-named scratch entry that earns a `Mod:crashify_beta`
-- crash property. Same shape and purpose as crashify_alpha: nil-return
-- descriptor that only logs execution and stands as a stable Crashify key.
--
-- Install: this folder ships as part of the metadata/crashify scenario bundle.
-- Copy mods/crashify_beta/ into <mod_path>/mods/crashify_beta/ and list
-- `crashify_beta` in <mod_path>/mods/mods.lst (the bundle's mods.lst already
-- does). No file output; console prefix `[CRASHIFY_BETA]`.
--
-- This probe is intentionally inert: it touches no engine state, installs no
-- hooks, and reads nothing from disk. It must never become a failure source.

local _print = print or __print or function() end
local _pcall = pcall

return {
    run = function()
        _pcall(_print, "[CRASHIFY_BETA] run executed (nil-return descriptor)")
    end,
}
