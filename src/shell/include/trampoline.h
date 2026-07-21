/*
 * trampoline.h — pure helpers for the production trampoline.
 *
 * The trampoline chunk (set MOD_LOADER_DIR + RELAY_MOD_PATH -> io.open the
 * staged entry -> read -> loadstring -> run) is the proven engine-context
 * entry mechanism (see dllmain.c). The production path uses TWO roots:
 *   - the mod loader root (`mod_loader_dir`) — where init.lua + its modules
 *     live (runtime-controlled; self-located by the shell next to the DLL at
 *     <dll-dir>\mod_loader);
 *   - the mod root (`mod_path`) — where DMF + user mods + mods.lst live
 *     (user/mod-manager-controlled; optional — mods just won't load if unset).
 * The entry path is `<mod_loader_dir>\init.lua`. trampoline_build_chunk bakes
 * all three into the chunk: it sets MOD_LOADER_DIR from the mod loader root,
 * RELAY_MOD_PATH from the mod root (empty string if unset), and opens the
 * joined entry path. Kept separate from the hook-heavy dllmain.c so the pure
 * logic is unit-testable (compiled directly into the C test exes, like
 * launcher.c's testable seams).
 */
#ifndef RELAY_TRAMPOLINE_H
#define RELAY_TRAMPOLINE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Join a directory `dir` and a filename `name` into one Windows-canonical path
 * with exactly one backslash separator: if `dir` already ends in a backslash or
 * forward slash no separator is added, otherwise a single backslash is inserted.
 * (Backslash is the documented canonical separator — works on native Windows
 * and Proton alike.) Writes up to (out_cap - 1) chars + NUL to `out`. Returns
 * the path length (excluding NUL), or -1 on a NULL arg, zero cap, empty `dir`,
 * empty `name`, or overflow. Pure and side-effect-free.
 */
int trampoline_join_path(const char *dir, const char *name,
                         char *out, size_t out_cap);

/*
 * Escape `path` (length `path_len`) into a Lua double-quoted-string-safe form:
 * backslash and double-quote are doubled (so the Lua parser yields the original
 * byte sequence). Forward slashes and all other bytes pass through unchanged.
 * Writes up to (out_cap - 1) chars + NUL to `out`. Returns the number of chars
 * written (excluding NUL), or -1 on a NULL arg, zero cap, or overflow.
 *
 * Pure and side-effect-free.
 */
int trampoline_escape_path(const char *path, size_t path_len,
                           char *out, size_t out_cap);

/*
 * Build the trampoline Lua chunk. Sets MOD_LOADER_DIR from `mod_loader_dir`
 * (escaped) and RELAY_MOD_PATH from `mod_path` (escaped, or the empty
 * string when `mod_path` is NULL/empty — the rite treats an empty mod root as
 * "no mods", gracefully), then opens + loads + runs `entry_path` (escaped).
 * The chunk:
 *
 *   MOD_LOADER_DIR = "<mod_loader_dir>"
 *   RELAY_MOD_PATH = "<mod_path>"
 *   local f, err = io.open("<entry_path>", "r")
 *   if not f then return "FAIL io.open: " .. tostring(err) end
 *   local data = f:read("*all"); f:close()
 *   local fn, lerr = loadstring(data)
 *   if not fn then return "FAIL loadstring: " .. tostring(lerr) end
 *   local ok, rerr = pcall(fn)
 *   if not ok then return "FAIL run: " .. tostring(rerr) end
 *   return "OK"
 *
 * The two globals hand the roots to the mod loader: MOD_LOADER_DIR roots its
 * own module loads (bootstrap_load); RELAY_MOD_PATH roots Mods.file.*
 * (DMF/mods/mods.lst). MOD_LOADER_DIR is an INTERNAL global set by the
 * trampoline (not a user env var/flag). (In the production call site
 * `mod_loader_dir` is also the prefix of `entry_path`, so it appears twice in
 * the chunk — once as the global, once inside the io.open path. That is
 * intended.)
 *
 * It returns a status string: "OK" if every step succeeded, else "FAIL <step>:
 * <err>" identifying which step broke. Writes the NUL-terminated chunk to `out`.
 * Returns the chunk length (excluding NUL), or -1 on a NULL arg
 * (`mod_loader_dir`, `entry_path`, or `out`), zero cap, empty `mod_loader_dir`,
 * empty `entry_path`, or overflow. (`mod_path` NULL/empty is NOT an error — it
 * yields the empty-string global.) Pure and side-effect-free.
 */
int trampoline_build_chunk(const char *mod_loader_dir, const char *mod_path,
                           const char *entry_path, char *out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* RELAY_TRAMPOLINE_H */
