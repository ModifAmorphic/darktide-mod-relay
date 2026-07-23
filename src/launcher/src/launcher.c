/*
 * launcher.c — CreateRemoteThread DLL injector.
 *
 * Creates Darktide.exe in a SUSPENDED state, injects relay_shell.dll via
 * CreateRemoteThread(LoadLibraryA, <dllpath>), waits for the DLL to signal
 * that the lua_newstate hook is ready, then resumes. Zero files land in the
 * game directory (the DLL is loaded from a staging path).
 *
 * Flow: CreateProcess(SUSPENDED) → inject → wait for hook-ready → ResumeThread,
 * with the correct Steam appID set in the child environment. The hook-ready
 * wait is essential: DllMain returns instantly (it only spawns a worker), and
 * the worker doesn't enable the lua_newstate hook until after discovery
 * completes — resuming before the hook is ready means the engine calls
 * lua_newstate before the hook is installed, so the hook never fires.
 *
 * Configuration model: every setting is flag > env > default. Game arguments
 * are NOT a setting — they are the verbatim rest-of-line after `--`.
 *   --game-binary <path>       [RELAY_GAME_BINARY]                REQUIRED
 *   --mod-path <path>          [RELAY_MOD_PATH]                   (optional; trampoline skips if unset)
 *   --log-file <path>          [RELAY_LOG_FILE]                   <launcher-dir>\relay.log
 *   --log-level <level>        [RELAY_LOG_LEVEL]                  info
 *   --steam-app-id <id>        [RELAY_STEAM_APP_ID]               1361210
 *   --version                  (value-less)                      print version and exit
 *   --lua-logs                 (value-less)                      tee Lua print output into relay.log
 *                                                                [RELAY_LUA_LOGS=1] (default: off)
 *   --                         (end-of-options separator)        rest-of-line forwarded to the game
 *
 * `--` ends Relay's option parsing: EVERY token after it is forwarded to the
 * game verbatim as a separate argv entry, in order, CRT-quoted by the builder
 * and appended after the quoted exe. Relay's own flags must precede `--`; a
 * token that looks like `--version` or `--mod-path` after `--` is a raw game
 * argument, not a Relay flag. The `--` itself is consumed (not forwarded). No
 * `--` (or no tokens after it) yields the legacy exe-only launch byte-for-byte.
 * Example: `--game-binary X -- --lua-heap-mb-size 2048` forwards two game
 * arguments (`--lua-heap-mb-size` and `2048`). There is no env serialization of
 * the game-argument tail — the only input path is the command line after `--`.
 * --version prints the build-injected product version (RELAY_VERSION) and exits.
 *
 * Command-line quoting is ANSI only (the Windows active code page).
 * Darktide.exe arguments are ASCII (relative paths, ini-section identifiers,
 * HTTPS URLs); there is no known Darktide argument that takes a non-ANSI
 * value, so the launcher stays on CreateProcessA. If a non-ANSI value ever
 * needs forwarding, the launcher must widen to CreateProcessW (a separate
 * change). The full command line is capped at RELAY_CMDLINE_MAX (32,767 chars
 * incl. NUL — the CreateProcessA ceiling); an oversize line is rejected before
 * any process is created.
 *
 * The injected DLL is hardcoded to <launcher-dir>\relay_shell.dll (the shell
 * self-locates the mod loader from its own path) — NOT configurable.
 *
 * Windows native: build with cl.exe or x86_64-w64-mingw32-gcc.
 * Proton: build the launcher for Windows (mingw) and run it under Wine inside
 * the Steam Proton prefix (see docs/architecture/MOD-RELAY.md).
 */
#include "launcher.h"
#include <stdio.h>
#include <string.h>

/* ---- config: defaults + env var names ------------------------------------ */

/* Product version. Injected at build time from .release-please-manifest.json
 * (-DRELAY_VERSION="x.y.z") so --version reports the version release-please
 * bumped for this build, with no version constant baked into source. The
 * fallback covers builds that don't pass the define (e.g. an ad-hoc compile). */
#ifndef RELAY_VERSION
#define RELAY_VERSION "0.0.0-dev"
#endif

#define RELAY_DEFAULT_STEAM_APPID "1361210"
#define RELAY_DEFAULT_LOG_LEVEL   "info"
#define RELAY_DEFAULT_SHELL_NAME  "relay_shell.dll"
#define RELAY_DEFAULT_LOG_NAME    "relay.log"

#define ENV_GAME_BINARY  "RELAY_GAME_BINARY"
#define ENV_MOD_PATH     "RELAY_MOD_PATH"
#define ENV_LOG_FILE     "RELAY_LOG_FILE"
#define ENV_LOG_LEVEL    "RELAY_LOG_LEVEL"
#define ENV_STEAM_APP_ID "RELAY_STEAM_APP_ID"
#define ENV_LUA_LOGS     "RELAY_LUA_LOGS"   /* exact value "1" enables the lua-print sink */

/* Named event for the launcher<->shell hook-ready handshake. Created
 * session-local (no Global\ prefix — avoids SeCreateGlobalPrivilege; launcher
 * and target run in the same session) before injection; the shell signals it
 * after MH_EnableHook succeeds. Must match shell/src/dllmain.c. */
#define RELAY_HOOK_READY_EVENT "relay_hook_ready"

/* Buffer size for a resolved path. Generously above MAX_PATH (260) so long
 * staging paths and extended-length paths don't silently truncate. */
#define RELAY_PATH_MAX 1024

/* testable helpers get external linkage under the test build so unit tests
 * can call them; production keeps them file-static. */
#ifdef RELAY_TEST_BUILD
#define RELAY_INTERNAL
#else
#define RELAY_INTERNAL static
#endif

/* ---- testable seams (extracted for unit testing) ---- */

void set_steam_env(const char *app_id) {
    SetEnvironmentVariableA("SteamAppId", app_id);
    SetEnvironmentVariableA("SteamGameId", app_id);
}

int inject_and_resume(const char *game_exe, const char *dll_path,
                      DWORD hook_timeout, char *cmdline) {
    HANDLE hook_ready = NULL;
    STARTUPINFOA si = { .cb = sizeof(si) };
    PROCESS_INFORMATION pi = {0};

    /* 0. Fail-fast pre-checks: verify both paths exist before creating any
     *    process. A bad path would otherwise have CreateRemoteThread run
     *    LoadLibraryA on a NULL/missing module (LoadLibraryA returns NULL
     *    fast) and then wait out hook_timeout on the hook-ready event, which
     *    never fires. Catch typos / bad paths up front instead. */
    if (GetFileAttributesA(game_exe) == INVALID_FILE_ATTRIBUTES) {
        fprintf(stderr, "[launcher] error: game exe not found: %s\n", game_exe);
        return 1;
    }
    if (GetFileAttributesA(dll_path) == INVALID_FILE_ATTRIBUTES) {
        fprintf(stderr, "[launcher] error: DLL not found: %s\n", dll_path);
        return 1;
    }

    /* 1. CreateProcess(SUSPENDED). The hook (lua_newstate) must be installed
     *    before the engine's main() runs; SUSPENDED + inject + wait-hook-ready
     *    + resume gives that timing guarantee. The caller-built cmdline (the
     *    quoted exe + rendered game arguments) is passed verbatim to
     *    CreateProcessA's lpCommandLine; it points at main()'s mutable buffer. */
    if (!CreateProcessA(game_exe, cmdline, NULL, NULL, FALSE,
                        CREATE_SUSPENDED, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "[launcher] error: CreateProcess(SUSPENDED) "
                "(GetLastError=%lu)\n", GetLastError());
        return 1;
    }
    printf("[launcher] created %s pid=%lu (suspended)\n",
           game_exe, pi.dwProcessId);

    /* 2. Allocate + write the DLL path into the target process. */
    size_t path_len = strlen(dll_path) + 1;
    LPVOID remote = VirtualAllocEx(pi.hProcess, NULL, path_len,
                                   MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) {
        fprintf(stderr, "[launcher] error: VirtualAllocEx "
                "(GetLastError=%lu)\n", GetLastError());
        goto kill;
    }
    if (!WriteProcessMemory(pi.hProcess, remote, dll_path, path_len, NULL)) {
        fprintf(stderr, "[launcher] error: WriteProcessMemory "
                "(GetLastError=%lu)\n", GetLastError());
        goto kill;
    }

    /* 3. Create the hook-ready event before CreateRemoteThread, so it exists
     *    before the DLL's worker can OpenEvent it (manual-reset, initially
     *    non-signaled; session-local name). */
    hook_ready = CreateEventA(NULL, TRUE, FALSE, RELAY_HOOK_READY_EVENT);
    if (!hook_ready) {
        fprintf(stderr, "[launcher] error: CreateEvent(hook_ready) "
                "(GetLastError=%lu)\n", GetLastError());
        goto kill;
    }

    /* 4. CreateRemoteThread(LoadLibraryA, remote_dll_path). */
    HMODULE k32 = GetModuleHandleA("kernel32.dll");
    FARPROC load_lib = GetProcAddress(k32, "LoadLibraryA");
    if (!load_lib) {
        fprintf(stderr, "[launcher] error: GetProcAddress LoadLibraryA "
                "(GetLastError=%lu)\n", GetLastError());
        goto kill;
    }
    HANDLE th = CreateRemoteThread(pi.hProcess, NULL, 0,
                                   (LPTHREAD_START_ROUTINE)load_lib, remote,
                                   0, NULL);
    if (!th) {
        fprintf(stderr, "[launcher] error: CreateRemoteThread "
                "(GetLastError=%lu)\n", GetLastError());
        goto kill;
    }
    printf("[launcher] injected %s via CreateRemoteThread\n", dll_path);

    /* 5. Wait for LoadLibraryA to return (DllMain ran). DllMain returns
     *    immediately — it only spawns a worker — so this just confirms the
     *    DLL is loaded; the hook is NOT ready yet. A timeout here means DllMain
     *    hung (e.g. the worker blocked under the loader lock); the LoadLibraryA
     *    thread may still be running and referencing `remote`, so we must NOT
     *    free it out from under the thread — terminate the process instead. */
    DWORD lt = WaitForSingleObject(th, 10000);
    if (lt != WAIT_OBJECT_0) {
        fprintf(stderr, "[launcher] error: LoadLibraryA thread %s (GetLastError=%lu)\n",
                lt == WAIT_TIMEOUT ? "timed out (DllMain hung)" : "wait failed",
                GetLastError());
        CloseHandle(th);
        goto kill;
    }
    /* LoadLibraryA returned: the remote thread's exit code is its return
     * value — the loaded module handle, or 0 on failure. A 0 here means the
     * DLL exists but failed to load (missing dependencies, wrong arch, etc.).
     * Fail fast instead of waiting out the hook-ready timeout, which would
     * never fire for a DLL whose DllMain never ran. Must read before
     * CloseHandle(th) — the exit code is gone once the handle is. */
    DWORD exit_code = 0;
    if (!GetExitCodeThread(th, &exit_code)) {
        fprintf(stderr, "[launcher] error: GetExitCodeThread "
                "(GetLastError=%lu)\n", GetLastError());
        CloseHandle(th);
        goto kill;
    }
    if (exit_code == 0) {
        fprintf(stderr, "[launcher] error: DLL load failed: %s "
                "(LoadLibraryA returned NULL — missing dependencies? "
                "wrong architecture?)\n", dll_path);
        CloseHandle(th);
        goto kill;
    }
    CloseHandle(th);
    VirtualFreeEx(pi.hProcess, remote, 0, MEM_RELEASE);

    /* 6. Wait for the worker to install + enable the lua_newstate hook before
     *    letting the engine's main() run. The worker signals hook_ready after
     *    MH_EnableHook succeeds. On timeout/failure we terminate rather than
     *    resume with an unready hook. */
    DWORD w = WaitForSingleObject(hook_ready, hook_timeout);
    if (w != WAIT_OBJECT_0) {
        fprintf(stderr, "[launcher] error: %s (GetLastError=%lu)\n",
                w == WAIT_TIMEOUT ? "hook-ready timeout"
                                   : "hook-ready wait failed",
                GetLastError());
        goto kill;
    }
    printf("[launcher] hook ready; resuming\n");

    /* 7. Resume the engine's main thread — the lua_newstate hook is armed. */
    if (ResumeThread(pi.hThread) == (DWORD)-1) {
        fprintf(stderr, "[launcher] error: ResumeThread "
                "(GetLastError=%lu)\n", GetLastError());
        goto kill;
    }

    /* The resolved log file is published to the child env by main() before
     * this call; read it back so the "where are the logs" hint is accurate. */
    {
        char log_buf[RELAY_PATH_MAX];
        DWORD ln = GetEnvironmentVariableA(ENV_LOG_FILE, log_buf,
                                           sizeof(log_buf));
        if (ln > 0 && ln < sizeof(log_buf)) {
            printf("[launcher] resumed; game should reach main menu. "
                   "Logs -> %s\n", log_buf);
        } else {
            printf("[launcher] resumed; game should reach main menu.\n");
        }
    }
    CloseHandle(hook_ready);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;

kill:
    TerminateProcess(pi.hProcess, 1);
    if (hook_ready) CloseHandle(hook_ready);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 1;
}

/* ---- command-line builder (MSVC CRT quoting) ----------------------------- */

/* Append a single byte to buf at *pos. Each write must leave room for the
 * eventual NUL terminator, so a byte is accepted only when the byte AND the
 * NUL both fit (pos + 2 <= bufsize). Returns 0 on success, -1 on overflow. */
static int cmdline_putc(char *buf, size_t bufsize, size_t *pos, char c) {
    if (*pos + 2 > bufsize) return -1;
    buf[(*pos)++] = c;
    return 0;
}

/* Append n copies of c. Returns 0 on success, -1 on overflow. */
static int cmdline_putn(char *buf, size_t bufsize, size_t *pos, char c,
                        size_t n) {
    for (size_t k = 0; k < n; k++) {
        if (cmdline_putc(buf, bufsize, pos, c) != 0) return -1;
    }
    return 0;
}

/* Render one game-argument token with the canonical MSVC CRT minimal quoting
 * algorithm. Returns 0 on success, -1 on overflow.
 *
 *   - empty token  -> ""
 *   - no space/tab/" -> verbatim (bare; backslashes are literal and safe since
 *     none is followed by a ")
 *   - otherwise     -> quoted: walk runs of backslashes; on " emit 2*run then
 *     one more backslash then "; on any other char emit run backslashes then
 *     the char; at end emit 2*run (trailing backslashes doubled because they
 *     precede the closing "), then close the quote. */
static int render_token(char *buf, size_t bufsize, size_t *pos,
                        const char *token) {
    if (token[0] == '\0') {
        if (cmdline_putc(buf, bufsize, pos, '"') != 0) return -1;
        if (cmdline_putc(buf, bufsize, pos, '"') != 0) return -1;
        return 0;
    }

    int need_quote = 0;
    for (const char *p = token; *p; p++) {
        if (*p == ' ' || *p == '\t' || *p == '"') { need_quote = 1; break; }
    }
    if (!need_quote) {
        for (const char *p = token; *p; p++) {
            if (cmdline_putc(buf, bufsize, pos, *p) != 0) return -1;
        }
        return 0;
    }

    if (cmdline_putc(buf, bufsize, pos, '"') != 0) return -1;
    size_t run = 0;
    for (const char *p = token; *p; p++) {
        if (*p == '\\') {
            run++;
        } else if (*p == '"') {
            if (cmdline_putn(buf, bufsize, pos, '\\', 2 * run + 1) != 0)
                return -1;
            if (cmdline_putc(buf, bufsize, pos, '"') != 0) return -1;
            run = 0;
        } else {
            if (cmdline_putn(buf, bufsize, pos, '\\', run) != 0) return -1;
            if (cmdline_putc(buf, bufsize, pos, *p) != 0) return -1;
            run = 0;
        }
    }
    /* Trailing backslashes are doubled: they immediately precede the closing ". */
    if (cmdline_putn(buf, bufsize, pos, '\\', 2 * run) != 0) return -1;
    if (cmdline_putc(buf, bufsize, pos, '"') != 0) return -1;
    return 0;
}

RELAY_INTERNAL int relay_build_command_line(const char *exe,
                                            const char *const *args,
                                            int arg_count,
                                            char *buf, size_t bufsize) {
    if (exe == NULL) return -1;
    size_t pos = 0;

    /* argv[0]: the exe, always wrapped in double quotes with bytes emitted
     * VERBATIM (no backslash escaping). This is byte-for-byte the legacy
     * "\"%s\"" form, so the zero-arg output is unchanged. Safe because the exe
     * path is launcher-resolved, Windows paths contain no U+0022, and any
     * backslashes it contains are not followed by a " (so they re-parse as
     * literal under the CRT rules). Caveat: a game-binary path ending in '\'
     * would mis-parse under the CRT (its trailing backslash precedes the closing
     * quote we append); this matches the legacy form and game-binary paths never
     * end in '\'. */
    if (cmdline_putc(buf, bufsize, &pos, '"') != 0) return -1;
    for (const char *p = exe; *p; p++) {
        if (cmdline_putc(buf, bufsize, &pos, *p) != 0) return -1;
    }
    if (cmdline_putc(buf, bufsize, &pos, '"') != 0) return -1;

    /* Each game argument, separated by a single space, CRT-quoted. */
    for (int i = 0; i < arg_count; i++) {
        if (args == NULL || args[i] == NULL) return -1;  /* defensive */
        if (cmdline_putc(buf, bufsize, &pos, ' ') != 0) return -1;
        if (render_token(buf, bufsize, &pos, args[i]) != 0) return -1;
    }

    buf[pos] = '\0';  /* always fits: every putc reserved room for it */
    return 0;
}

/* ---- config resolution (flag > env > default) ---------------------------- */

/* Resolver-owned stable storage for values not sourced from argv. One buffer
 * per setting so a resolve never clobbers another setting mid-call. Reused
 * across resolve_config() calls — callers must copy out before re-resolving. */
static char g_game_binary_buf[RELAY_PATH_MAX];
static char g_mod_path_buf[RELAY_PATH_MAX];
static char g_log_file_buf[RELAY_PATH_MAX];
static char g_log_level_buf[32];
static char g_steam_app_id_buf[32];

/* Reads env_name into out. Returns 1 if the var is set and fit in outsz, 0 if
 * unset, empty, too long, or errored (treated as "not provided" so the next
 * precedence level — default — applies). */
static int read_env(const char *env_name, char *out, size_t outsz) {
    DWORD n = GetEnvironmentVariableA(env_name, out, (DWORD)outsz);
    if (n == 0 || n >= outsz) return 0;  /* unset/error, or truncated */
    return 1;
}

/* Returns 1 only if env_name is set to exactly "1" (byte-for-byte). Unset,
 * empty, "0", "true", whitespace, oversized (would truncate the probe buffer),
 * and all other values return 0. This is the exact-match policy for the
 * value-less RELAY_LUA_LOGS switch: only the canonical "1" enables. */
static int env_is_exact_one(const char *env_name) {
    char buf[16];
    DWORD n = GetEnvironmentVariableA(env_name, buf, sizeof(buf));
    if (n == 0 || n >= sizeof(buf)) return 0;
    return strcmp(buf, "1") == 0 ? 1 : 0;
}

/* Fills dir_buf with the launcher exe's directory (no trailing backslash), or
 * "." if it can't be determined (GetModuleFileNameA failed/truncated, or no
 * path separator present). */
static void get_launcher_dir(char *dir_buf, size_t dir_sz) {
    char self[RELAY_PATH_MAX];
    DWORD n = GetModuleFileNameA(NULL, self, sizeof(self));
    if (n == 0 || n >= sizeof(self)) {
        snprintf(dir_buf, dir_sz, ".");
        return;
    }
    char *slash = strrchr(self, '\\');
    if (!slash) {
        snprintf(dir_buf, dir_sz, ".");
        return;
    }
    size_t dirlen = (size_t)(slash - self);
    if (dirlen + 1 > dir_sz) {
        snprintf(dir_buf, dir_sz, ".");
        return;
    }
    memcpy(dir_buf, self, dirlen);
    dir_buf[dirlen] = '\0';
}

/* Builds "<launcher-dir>\<leaf>" into out (the default for path settings). */
static void build_default_path(char *out, size_t outsz, const char *leaf) {
    char dir[RELAY_PATH_MAX];
    get_launcher_dir(dir, sizeof(dir));
    snprintf(out, outsz, "%s\\%s", dir, leaf);
}

RELAY_INTERNAL int relay_parse_args(int argc, char **argv,
                                    relay_parsed_args *out) {
    memset(out, 0, sizeof(*out));

    for (int i = 1; i < argc; i++) {
        const char *flag = argv[i];

        /* `--` ends option parsing. Every token after it is the game-argument
         * tail: forwarded to the game verbatim as separate argv entries, in
         * order, with NO further flag interpretation (a token that looks like
         * --version or --mod-path after -- is a raw game arg, not a Relay
         * flag). The `--` itself is consumed (not forwarded). The tail is a
         * borrowed slice of argv (stable for the process lifetime), so no
         * heap allocation. */
        if (strcmp(flag, "--") == 0) {
            int tail = argc - i - 1;
            /* Cast char** -> const char**: safe (strings are read-only here).
             * C forbids the implicit T** -> const T** conversion. */
            out->game_arguments = (tail > 0) ? (const char **)&argv[i + 1] : NULL;
            out->game_argument_count = tail;
            return 0;
        }

        if (strcmp(flag, "-h") == 0 || strcmp(flag, "--help") == 0) return -2;

        /* --version: value-less flag. Does NOT consume the following token
         * (so {"--version","--game-binary","G"} still parses --game-binary).
         * main() prints the build-injected version and exits 0. */
        if (strcmp(flag, "--version") == 0) {
            out->show_version = 1;
            continue;
        }

        /* --lua-logs: value-less flag. Does NOT consume the following token
         * (so {"--lua-logs","--game-binary","G"} still parses --game-binary).
         * Sets the parsed lua_logs_enabled field; relay_resolve_config turns
         * it into the resolved cfg->lua_logs_enabled (flag > env > default).
         * Only recognized before `--` (after `--` it is a raw game arg). */
        if (strcmp(flag, "--lua-logs") == 0) {
            out->lua_logs_enabled = 1;
            continue;
        }

        /* single-value flags */
        const char **target;
        if      (strcmp(flag, "--game-binary")   == 0) target = &out->game_binary;
        else if (strcmp(flag, "--mod-path")      == 0) target = &out->mod_path;
        else if (strcmp(flag, "--log-file")      == 0) target = &out->log_file;
        else if (strcmp(flag, "--log-level")     == 0) target = &out->log_level;
        else if (strcmp(flag, "--steam-app-id")  == 0) target = &out->steam_app_id;
        else {
            fprintf(stderr, "[launcher] error: unknown flag: %s\n", flag);
            return -1;
        }

        if (i + 1 >= argc) {
            fprintf(stderr, "[launcher] error: missing value for %s\n", flag);
            return -1;
        }
        *target = argv[++i];
    }
    return 0;
}

RELAY_INTERNAL void relay_resolve_config(const relay_parsed_args *args,
                                         relay_config *cfg) {
    /* game_arguments: purely flag-driven (the `--` rest-of-line tail) — no
     * env/default layer. Threaded through unchanged; it's a borrowed slice of
     * argv (not heap-owned), so nothing to free. */
    cfg->game_arguments = args->game_arguments;
    cfg->game_argument_count = args->game_argument_count;

    /* game_binary: required — no default, NULL if both flag and env are unset
     * (main() rejects this with usage). */
    cfg->game_binary = args->game_binary
        ? args->game_binary
        : (read_env(ENV_GAME_BINARY, g_game_binary_buf, sizeof(g_game_binary_buf))
              ? g_game_binary_buf : NULL);

    /* mod_path: optional — NULL (unset) means the trampoline emits an empty
     * RELAY_MOD_PATH (mods just won't load). */
    if (args->mod_path) {
        cfg->mod_path = args->mod_path;
    } else if (read_env(ENV_MOD_PATH, g_mod_path_buf, sizeof(g_mod_path_buf))) {
        cfg->mod_path = g_mod_path_buf;
    } else {
        cfg->mod_path = NULL;
    }

    /* log_file: default <launcher-dir>\relay.log */
    if (args->log_file) {
        cfg->log_file = args->log_file;
    } else if (read_env(ENV_LOG_FILE, g_log_file_buf, sizeof(g_log_file_buf))) {
        cfg->log_file = g_log_file_buf;
    } else {
        build_default_path(g_log_file_buf, sizeof(g_log_file_buf),
                           RELAY_DEFAULT_LOG_NAME);
        cfg->log_file = g_log_file_buf;
    }

    /* log_level: default info */
    cfg->log_level = args->log_level
        ? args->log_level
        : (read_env(ENV_LOG_LEVEL, g_log_level_buf, sizeof(g_log_level_buf))
              ? g_log_level_buf : RELAY_DEFAULT_LOG_LEVEL);

    /* steam_app_id: default 1361210 */
    cfg->steam_app_id = args->steam_app_id
        ? args->steam_app_id
        : (read_env(ENV_STEAM_APP_ID, g_steam_app_id_buf, sizeof(g_steam_app_id_buf))
              ? g_steam_app_id_buf : RELAY_DEFAULT_STEAM_APPID);

    /* lua_logs_enabled: an explicit --lua-logs flag enables; otherwise only the
     * exact env value RELAY_LUA_LOGS=1 enables. Default off. No negative
     * switch — unset/empty/"0"/"true"/whitespace/oversized/all-other-values
     * all resolve to disabled. */
    cfg->lua_logs_enabled = args->lua_logs_enabled ? 1 : env_is_exact_one(ENV_LUA_LOGS);
}

/* ---- usage --------------------------------------------------------------- */

static void print_usage(FILE *out, const char *prog) {
    fprintf(out,
        "Usage: %s --game-binary <path> [options]\n"
        "\n"
        "Create Darktide.exe in a suspended state, inject relay_shell.dll via\n"
        "CreateRemoteThread, wait for the lua_newstate hook to arm, then resume.\n"
        "Zero files land in the game directory.\n"
        "\n"
        "Every setting follows: flag > env var > default.\n"
        "\n"
        "Required:\n"
        "  --game-binary <path>   Darktide.exe\n"
        "                         [env: RELAY_GAME_BINARY]\n"
        "\n"
        "Optional:\n"
        "  --mod-path <path>      staged mods dir; mods won't load if unset\n"
        "                         [env: RELAY_MOD_PATH] [default: unset]\n"
        "  --log-file <path>      launcher/shell log file\n"
        "                         [env: RELAY_LOG_FILE]\n"
        "                         [default: <launcher-dir>\\relay.log]\n"
        "  --log-level <level>    one of: error warn info debug trace\n"
        "                         [env: RELAY_LOG_LEVEL] [default: info]\n"
        "  --steam-app-id <id>    Steam app id\n"
        "                         [env: RELAY_STEAM_APP_ID]\n"
        "                         [default: 1361210]\n"
        "\n"
        "  --lua-logs              include Lua print output in relay.log\n"
        "                         (value-less; only the exact env value\n"
        "                         RELAY_LUA_LOGS=1 enables)\n"
        "                         [env: RELAY_LUA_LOGS=1] [default: off]\n"
        "\n"
        "  --                     end-of-options separator: every token after\n"
        "                         -- is forwarded to the game verbatim, in\n"
        "                         order, as a separate argument (e.g.\n"
        "                         --game-binary X -- --lua-heap-mb-size 2048\n"
        "                         forwards --lua-heap-mb-size and 2048). All\n"
        "                         flags above must precede --; a token that\n"
        "                         looks like a flag after -- is a raw game\n"
        "                         argument. No -- (or nothing after it) is the\n"
        "                         legacy exe-only launch. ANSI only (active\n"
        "                         code page); the full line is capped at\n"
        "                         32,767 chars.\n"
        "  --version               print the launcher version (build-injected)\n"
        "                         and exit\n"
        "\n"
        "  -h, --help             show this help and exit\n"
        "\n"
        "The injected DLL is hardcoded to <launcher-dir>\\relay_shell.dll (the\n"
        "shell self-locates the mod loader from its own path); it is not\n"
        "configurable. <launcher-dir> is the directory of this exe (fall back\n"
        "to '.' if the launcher path can't be resolved).\n",
        prog);
}

/* ---- entry point (excluded when building test objects) ---- */

#ifndef RELAY_TEST_BUILD
int main(int argc, char **argv) {
    relay_parsed_args args;
    int pr = relay_parse_args(argc, argv, &args);
    if (pr == -2) {
        print_usage(stdout, argv[0]);
        return 0;
    }
    if (pr == -1) {
        print_usage(stderr, argv[0]);
        return 2;
    }

    /* --version: print the build-injected product version and exit 0 — but
     * only when parse fully succeeded (returned 0). -h/--help (parse returns
     * -2) and parse errors (unknown flag / missing value, returns -1) are
     * checked above and take precedence, so e.g. `--version --help` prints help
     * and `--version --bogus x` errors out. Reaching here also means --version
     * appeared BEFORE `--` (after `--` it's a raw game arg). Checked before the
     * required --game-binary check so it works on a bare command line (a caller
     * like Curator uses this for version comparison). */
    if (args.show_version) {
        printf("mod_relay %s\n", RELAY_VERSION);
        return 0;
    }

    relay_config cfg;
    relay_resolve_config(&args, &cfg);

    if (!cfg.game_binary) {
        fprintf(stderr, "[launcher] error: --game-binary is required "
                "(or set %s)\n", ENV_GAME_BINARY);
        print_usage(stderr, argv[0]);
        return 2;
    }

    /* Publish the resolved config to the child env so CreateProcessA(NULL
     * env) inherits it: Steam identity + shell logging + the mod root.
     * RELAY_MOD_PATH is set only when configured — leaving it unset means
     * the shell's trampoline emits an empty RELAY_MOD_PATH (mods won't load).
     * The shell self-locates the mod loader from its own DLL path, so no
     * loader-path env var is published. Game arguments are NOT published to
     * the env — they go on the child command line (built below). */
    set_steam_env(cfg.steam_app_id);
    SetEnvironmentVariableA(ENV_LOG_FILE, cfg.log_file);
    SetEnvironmentVariableA(ENV_LOG_LEVEL, cfg.log_level);
    if (cfg.mod_path) {
        SetEnvironmentVariableA(ENV_MOD_PATH, cfg.mod_path);
    }
    /* Canonical child inheritance for the value-less lua-print switch: set the
     * exact "1" when enabled, or REMOVE it when disabled so a stale parent
     * value can't leak into the child as a non-"1" (the shell snapshots only
     * the exact "1"). Preserves flag > env > default: the resolved boolean is
     * the single source of truth re-exported here. */
    if (cfg.lua_logs_enabled) {
        SetEnvironmentVariableA(ENV_LUA_LOGS, "1");
    } else {
        SetEnvironmentVariableA(ENV_LUA_LOGS, NULL);
    }

    /* The injected DLL is hardcoded next to the launcher. Existence of
     * game_binary + the DLL is validated by the fail-fast pre-checks inside
     * inject_and_resume. */
    char dll_path[RELAY_PATH_MAX];
    build_default_path(dll_path, sizeof(dll_path), RELAY_DEFAULT_SHELL_NAME);

    /* Build the child command line (quoted exe + CRT-quoted game arguments).
     * An oversize line is unlaunchable on Windows regardless; reject it here
     * before any process is created. Game arguments are a borrowed argv slice
     * (no heap), so nothing to free on any path. */
    char cmdline[RELAY_CMDLINE_MAX];
    if (relay_build_command_line(cfg.game_binary, cfg.game_arguments,
                                 cfg.game_argument_count,
                                 cmdline, sizeof(cmdline)) != 0) {
        fprintf(stderr, "[launcher] error: command line too long (>%d chars)\n",
                RELAY_CMDLINE_MAX - 1);
        return 2;
    }

    return inject_and_resume(cfg.game_binary, dll_path, 60000, cmdline);
}
#endif /* RELAY_TEST_BUILD */
