/*
 * trampoline.h — pure helpers for the production trampoline.
 *
 * The trampoline chunk (set MOD_LOADER_DIR + RELAY_MOD_PATH -> io.open the
 * staged entry -> read -> loadstring -> run) is the engine-context entry
 * mechanism (see dllmain.c). The production path uses TWO roots:
 *   - the mod loader root (`mod_loader_dir`) — where init.lua + its modules
 *     live (runtime-controlled; self-located by the shell next to the DLL at
 *     <dll-dir>\mod_loader; REQUIRED);
 *   - the mod root (`mod_path`) — where DMF + user mods + mods.lst live
 *     (user/mod-manager-controlled; OPTIONAL — mods just won't load if unset).
 * The entry path is `<mod_loader_dir>\init.lua`. These are pure string-op
 * helpers with no Windows/Lua/hook dependencies, so they compile directly into
 * the C test exes.
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
 * Build the trampoline Lua chunk from the two roots, the entry path, the
 * build-injected product version, and the splash-skip flag. The chunk sets
 * internal globals MOD_LOADER_DIR (from `mod_loader_dir`, escaped),
 * RELAY_MOD_PATH (from `mod_path`, escaped, or "" when NULL/empty — the loader
 * treats empty as "no mods"), MOD_RELAY_VERSION (from `relay_version` — nil
 * when NULL/empty/overlong, so malformed build metadata disables only version
 * diagnostics, not the loader), and RELAY_SKIP_SPLASH ("1" when `skip_splash`
 * is nonzero, "" otherwise — the loader checks `== "1"`), then io.open + reads
 * + loadstrings + runs `entry_path` (escaped). All four globals are an internal
 * bootstrap handoff, not user env vars or a public Lua-facility surface; the
 * loader retires them before community code runs.
 *
 * `skip_splash` is an int (0 or 1): it maps to a fixed Lua string token, so
 * unlike `mod_path` it needs no escaping.
 *
 * The chunk returns a status string: "OK" if every guarded step succeeded,
 * else "FAIL <step>: <err>" identifying which step broke. (The unguarded
 * f:read is the one step whose error is caught by the chunk's own pcall and
 * reported as CHUNK PCALL FAILED by trampoline_run.)
 *
 * (In the production call site `mod_loader_dir` is also the prefix of
 * `entry_path`, so it appears twice in the chunk — once as the global, once
 * inside the io.open path. That is intended.)
 *
 * Writes the NUL-terminated chunk to `out`. Returns the chunk length
 * (excluding NUL), or -1 on a NULL arg (`mod_loader_dir`, `entry_path`, or
 * `out`), zero cap, empty `mod_loader_dir`, empty `entry_path`, or overflow.
 * (`mod_path` NULL/empty is NOT an error — it yields the empty-string global.)
 * Pure and side-effect-free.
 */
int trampoline_build_chunk(const char *mod_loader_dir, const char *mod_path,
                           const char *entry_path, const char *relay_version,
                           int skip_splash,
                           char *out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* RELAY_TRAMPOLINE_H */
