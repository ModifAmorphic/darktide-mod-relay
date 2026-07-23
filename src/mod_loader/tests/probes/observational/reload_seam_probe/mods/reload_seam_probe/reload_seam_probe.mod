-- reload_seam_probe.mod -- manual live diagnostic (not a harness test; not shipped).
--
-- An outer-driven mod that overrides ModManager:_check_reload to return false,
-- demonstrating the reload trigger-detection seam is hookable by a mod (the
-- built-in LEFT Ctrl + LEFT Shift + R gesture is suppressed while this is
-- loaded). Use it to verify the seam works in the real game.
--
-- Install: this scenario ships a complete bundle — its directory is itself the
-- <mod_path>. Launch directly with
--   --mod-path <path-to-observational/reload_seam_probe>
-- in developer mode (the bundle's mods/mods.lst already lists exactly
-- `reload_seam_probe`); the built-in reload gesture should NOT fire while it is
-- loaded. See README.md in the scenario root for recovery/removal and safety.
return {
    run = function()
        if CLASS and type(CLASS.ModManager) == "table" then
            CLASS.ModManager._check_reload = function(self) return false end
        end
    end,
}
