-- reload_seam_probe.mod -- manual live diagnostic (not a harness test; not shipped).
--
-- An outer-driven mod that overrides ModManager:_check_reload to return false,
-- demonstrating the reload trigger-detection seam is hookable by a mod (the
-- built-in LEFT Ctrl + LEFT Shift + R gesture is suppressed while this is
-- loaded). Use it to verify the seam works in the real game.
--
-- Install: copy to <mod_path>/mods/reload_seam_probe/reload_seam_probe.mod and
-- add a `reload_seam_probe` line to mods.lst. Launch in developer mode; the
-- built-in reload gesture should NOT fire. Remove the line to restore it.
return {
    run = function()
        if CLASS and type(CLASS.ModManager) == "table" then
            CLASS.ModManager._check_reload = function(self) return false end
        end
    end,
}
