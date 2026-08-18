/*
 * trampoline.h — pure helpers for the production trampoline.
 *
 * Pure string-op helpers (no Windows/Lua/hook dependencies) that compile
 * directly into both the shell DLL and the C test exes. The trampoline's
 * game-safety and roots contracts are normative in
 * docs/reference/relay/shell.md; the per-global build contract is documented
 * at trampoline_build_chunk below.
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
 * Return 1 when s[0..len) contains a control byte (0x00-0x1F or 0x7F), else 0.
 * Plain byte-range check, deliberately locale-independent; high bytes (>= 0x80,
 * ANSI codepage path chars) are NOT control bytes. NULL s returns 0. Escape
 * covers only backslash/quote, so callers gate control-bearing values out
 * BEFORE staging (see docs/reference/relay/shell.md).
 * Pure and side-effect-free.
 */
int trampoline_path_has_control(const char *s, size_t len);

/*
 * Build the trampoline chunk: set the five internal globals — `mod_loader_dir`,
 * `mod_path`, `mod_manager` (escaped; NULL/empty mod_path/mod_manager => ""
 * global), `relay_version` (NULL/empty/overlong => nil), the `skip_splash`
 * token — then io.open/read/loadstring/run `entry_path`. Returns the chunk
 * length (excluding NUL), or -1 on a NULL `mod_loader_dir`/`entry_path`/`out`,
 * zero cap, empty `mod_loader_dir`/`entry_path`, or overflow. Per-global
 * build contract + status-string behavior ("OK" / "FAIL <step>: <err>"):
 * docs/reference/relay/shell.md. Pure and side-effect-free.
 */
int trampoline_build_chunk(const char *mod_loader_dir, const char *mod_path,
                           const char *mod_manager,
                           const char *entry_path, const char *relay_version,
                           int skip_splash,
                           char *out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* RELAY_TRAMPOLINE_H */
