/*
 * launcher.h — Public interface for the launcher's testable seams.
 *
 * Extracted from launcher.c so tests can call set_steam_env() and
 * inject_and_resume() (and, under RELAY_TEST_BUILD, the config helpers)
 * without going through main().
 */
#ifndef RELAY_LAUNCHER_H
#define RELAY_LAUNCHER_H

#include <windows.h>

/*
 * CreateProcessA's lpCommandLine ceiling: the documented max is 32,767
 * characters INCLUDING the terminating NUL (so ~32,766 usable). A command
 * line that would exceed it is unlaunchable on Windows regardless, so the
 * builder rejects it before any process is created. Shared by main(), the
 * command-line builder, and the injection tests, so it lives here.
 */
#define RELAY_CMDLINE_MAX 32767

/*
 * Resolved launcher configuration.
 *
 * Every setting follows the same precedence: flag > env > default. game_arguments
 * is NOT a setting — it is the verbatim rest-of-line after `--` (the
 * end-of-options separator), with NO env/default layer. See launcher.c for the
 * full table of flags, env vars, and defaults.
 *
 * The injected DLL is NOT configurable here: it is hardcoded to
 * <launcher-dir>\relay_shell.dll (the shell ships next to the launcher and
 * self-locates the mod loader from its own DLL path). game_binary has no
 * default (NULL if unresolved). Pointers are owned by the resolver; values
 * sourced from argv or string literals are stable for the process lifetime,
 * while env/default values live in resolver-owned static buffers (valid until
 * the next resolve). game_arguments is a borrowed slice of argv (the tail after
 * `--`), NOT heap-owned — nothing to free.
 */
typedef struct {
    const char *game_binary;      /* required: no default (NULL if unresolved)  */
    const char *mod_path;         /* optional: NULL => trampoline skips        */
    const char *log_file;         /* default: <launcher-dir>\relay.log */
    const char *log_level;        /* default: info                              */
    const char *steam_app_id;     /* default: 1361210                           */
    const char **game_arguments;  /* no env/default: borrowed `--` tail or NULL */
    int          game_argument_count;
} relay_config;

/*
 * Raw flag parse result; a field is NULL when its flag was not given.
 * Pointers alias argv (stable for the process lifetime). game_arguments is a
 * borrowed slice into argv — the tail after the end-of-options separator `--`
 * (NULL when `--` is absent or has nothing after it); it is NOT heap-owned, so
 * nothing to free. show_version is set by the value-less --version flag. Used
 * internally by main(); exposed here because relay_config carries the resolved
 * form.
 */
typedef struct {
    const char *game_binary;
    const char *mod_path;
    const char *log_file;
    const char *log_level;
    const char *steam_app_id;
    const char **game_arguments;  /* borrowed argv tail after `--` (NULL if none) */
    int          game_argument_count;
    int          show_version;  /* set by the value-less --version flag        */
} relay_parsed_args;

/*
 * Set SteamAppId and SteamGameId to app_id in the current process
 * environment. The child created by CreateProcessA inherits this block.
 */
void set_steam_env(const char *app_id);

/*
 * Full injection + handshake + resume flow.
 * Creates game_exe in SUSPENDED state, injects dll_path via
 * CreateRemoteThread(LoadLibraryA), waits for the hook-ready event
 * (hook_timeout ms), then resumes the main thread.
 *
 * cmdline is a MUTABLE, NUL-terminated command line for CreateProcessA's
 * lpCommandLine (built by relay_build_command_line): the quoted exe as argv[0]
 * followed by the rendered game arguments. lpCommandLine is in/out and may be
 * mutated by CreateProcessA, so it MUST point at a writable buffer (never a
 * string literal). main() owns the buffer.
 *
 * Returns 0 on success, 1 on any failure. On failure the child process
 * is terminated and all handles are cleaned up.
 */
int inject_and_resume(const char *game_exe, const char *dll_path,
                      DWORD hook_timeout, char *cmdline);

#ifdef RELAY_TEST_BUILD
/*
 * Internal config helpers — exposed (non-static) only for unit tests.
 * Production builds keep these file-static in launcher.c, where main()
 * (same translation unit) reaches them directly without a header prototype.
 */

/* Parse Relay's flags. `--` is the end-of-options separator: every token after
 * it becomes out->game_arguments (a borrowed slice of argv, NULL if none),
 * forwarded verbatim to the game — no flag is interpreted after `--`. The
 * value-less --version flag sets out->show_version.
 * Returns 0 on success, -1 on a bad/unknown flag or missing value (before --),
 * -2 on -h/--help (not an error). No heap allocation — nothing to free. */
int relay_parse_args(int argc, char **argv, relay_parsed_args *out);

/* Resolve flag > env > default into cfg (uses resolver-owned buffers for
 * values not sourced from argv). game_arguments is threaded through unchanged
 * (no env/default layer). */
void relay_resolve_config(const relay_parsed_args *args, relay_config *cfg);

/* Build the child command line for CreateProcessA: the exe as argv[0]
 * (always wrapped in double quotes, byte-for-byte the legacy form), followed
 * by each game argument rendered with the MSVC CRT quoting algorithm.
 *
 * ANSI only (the active code page): Darktide.exe arguments are ASCII (paths,
 * ini-section identifiers, HTTPS URLs) and Windows paths contain no U+0022, so
 * the exe is emitted verbatim. There is no known Darktide argument that takes a
 * non-ANSI value; if one ever exists the launcher must widen to CreateProcessW
 * (a separate change). This ANSI limitation is an explicit assumption, not a
 * silent one.
 *
 * Writes a NUL-terminated string into buf (which MUST be mutable —
 * CreateProcessA may modify it). Returns 0 on success, or -1 if exe is NULL,
 * an arg is NULL, or the result (including the NUL) would not fit in bufsize
 * (bufsize is the OS ceiling RELAY_CMDLINE_MAX; an overflow is unlaunchable on
 * Windows regardless, so it is rejected here before any process is created). On
 * a -1 (overflow) return buf is partially written and NOT NUL-terminated; the
 * caller must not use it in that case. */
int relay_build_command_line(const char *exe,
                             const char *const *args, int arg_count,
                             char *buf, size_t bufsize);

#endif /* RELAY_TEST_BUILD */

#endif /* RELAY_LAUNCHER_H */
