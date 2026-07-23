/*
 * dllmain.c — Mod Relay C shell (the injected DLL).
 *
 * Linked with the Rust `relay-discovery` staticlib (C-ABI) + MinHook into
 * one PE DLL, delivered by CreateRemoteThread. DllMain spawns a worker that:
 *   - calls the Rust `relay_discover` seam on the live Darktide.exe image
 *     to resolve the LuaJIT/engine function addresses;
 *   - installs two production MinHook detours — `lua_newstate` (captures the
 *     single Lua VM) and `lua_pcall` (drives the staged mod loader) — and
 *     signals hook-ready to the launcher;
 *   - stages the production trampoline chunk (self-locating the mod loader dir
 *     + reading the mod root) so it is ready to fire one-shot at pcall#1.
 *
 * Both hooks are required: without `lua_newstate` the Lua state is never
 * captured, and without `lua_pcall` the trampoline never runs. A failure to
 * install either is fatal (the worker logs FATAL and exits, leaving the game
 * running vanilla rather than half-modded).
 *
 * Production trampoline (the proven engine-context entry):
 *   On the FIRST lua_pcall (pcall #1) — one-shot, BEFORE the original pcall —
 *   the pcall detour runs the staged chunk. The chunk sets MOD_LOADER_DIR +
 *   RELAY_MOD_PATH, hands off the build-injected product version privately,
 *   io.opens the staged entry (`<MOD_LOADER_DIR>/init.lua`),
 *   reads it, loadstrings it, and runs it. This captures the engine's
 *   io/loadstring before the engine strips them from globals (~pcall#10); a
 *   chunk injected at pcall#1 sees the globals table directly (no setfenv
 *   sandbox at pcall#1 — chunk env = globals). The chunk returns "OK" or
 *   "FAIL <step>: <err>" and the shell logs the one-line status. See
 *   trampoline.h/c for the chunk template and path/env contract.
 *
 *   Two roots: MOD_LOADER_DIR (the loader dir — runtime-controlled, self-
 *   located by the shell from its own DLL path as <dll-dir>\mod_loader,
 *   REQUIRED; if unresolvable the trampoline is SKIPPED and the game runs
 *   vanilla) and RELAY_MOD_PATH (the mod dir — user/mod-manager-
 *   controlled, OPTIONAL; mods just won't load if unset).
 *
 * Game-safety: one-shot (Interlocked guard), synchronous on the engine's Lua
 * thread, g_in_trampoline set for the duration (the chunk's internal Lua pcall
 * re-enters lua_pcall but is skipped by the guard — no re-count, no re-run),
 * stack-clean (gettop saved / settop restored — zero net effect; the engine's
 * pcall args below base are untouched), lua_pcall never longjmps (errors are
 * returned), and the staged file is the runtime-controlled loader entry.
 *
 * Discovery note: the address table also carries `lua_resource::bytecode` (the
 * engine's bundle-script loader, resolved as the `stingray::lua_resource::
 * bytecode` string-anchor's containing function). It is logged as a validated
 * discovery output but NOT hooked — it is an engine C++ function with an
 * unknown signature/return convention, so a forwarding detour risks stack/return
 * corruption. `lua_pcall` (known LuaJIT C-API signature) is the safe injection
 * point. The other discovered anchors (lua_getfield/getfenv/setfenv/openlibs,
 * LuaEnvironment::init bounds) are likewise validated discovery outputs retained
 * for a stable ABI; the production shell consumes the subset it needs.
 *
 * Out of scope: DMF bootstrap, multi-shot injection, mod-manager UI. Logging
 * goes to OutputDebugString + a log file (RELAY_LOG_FILE env, or relay.log
 * beside the game exe), level-filtered via RELAY_LOG_LEVEL (default info).
 */
#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "relay_discovery.h"
#include "trampoline.h"
#include "log_sink.h"
#include "MinHook.h"

#ifndef RELAY_VERSION
#define RELAY_VERSION "0.0.0-dev"
#endif

/* Named event for the launcher<->shell hook-ready handshake. The launcher
 * creates this (session-local; no Global\ prefix) before injecting the DLL
 * and waits on it before resuming the main thread. Must match launcher.c. */
#define RELAY_HOOK_READY_EVENT "relay_hook_ready"

/* ---- minimal LuaJIT type stubs (only what the shell touches) ---- */
typedef struct lua_State lua_State;
typedef void *(*lua_Alloc)(void *ud, void *ptr, size_t osize, size_t nsize);
typedef lua_State *(*newstate_t)(lua_Alloc f, void *ud);
typedef int  (*gettop_t)(lua_State *L);
typedef void (*settop_t)(lua_State *L, int idx);
typedef int  (*loadbuffer_t)(lua_State *L, const char *buf, size_t size, const char *name);
typedef int  (*pcall_t)(lua_State *L, int nargs, int nresults, int errfunc);
typedef const char *(*tolstring_t)(lua_State *L, int idx, size_t *len);

/* ---- lua-print sink: LuaJIT 2.1 / Lua 5.1 C-API constants + types ----
 * Grounded against /usr/include/luajit-2.1/lua.h (LuaJIT 2.1.1784580905,
 * tracking Lua 5.1). Defined locally — the shell does not link lua.h — and
 * consumed only via RVAs already present in the discovered address table (no
 * new discovery, dependency, hook, or trampoline-chunk contract):
 *   LUA_GLOBALSINDEX = -10002   (lua.h:38, the pseudo-index for the globals
 *                                table; lua_setglobal is a macro over
 *                                lua_setfield(L, LUA_GLOBALSINDEX, s) per
 *                                lua.h:278, so we call setfield directly)
 *   LUA_TSTRING = 4             (lua.h:79)
 *   lua_CFunction = int(*)(lua_State*)               (lua.h:53)
 *   lua_pushcclosure(L, fn, n) -> void               (lua.h:169)
 *   lua_setfield(L, idx, k) -> void                  (lua.h:192; pops top into t[k])
 *   lua_type(L, idx) -> int                          (lua.h:140)
 *   lua_tolstring(L, idx, &len) -> const char*       (lua.h:150; already resolved) */
#define LUA_GLOBALSINDEX (-10002)
#define LUA_TSTRING      4
typedef int  (*lua_CFunction)(lua_State *L);
typedef void (*pushcclosure_t)(lua_State *L, lua_CFunction fn, int n);
typedef void (*setfield_t)(lua_State *L, int idx, const char *k);
typedef int  (*type_t)(lua_State *L, int idx);

/* ---- resolved from the discovered RVAs ----
 * Only the C-API pointers the production trampoline consumes. The other
 * discovered anchors (lua_getfield/getfenv/setfenv/openlibs/type, the engine
 * bundle-script loader, LuaEnvironment::init bounds) remain in the address
 * table as validated discovery outputs (ABI-stable) but are not hooked or
 * dereferenced here. */
static newstate_t   g_orig_newstate = NULL;
static pcall_t      g_orig_pcall = NULL;
static gettop_t     g_lua_gettop = NULL;
static settop_t     g_lua_settop = NULL;
static loadbuffer_t g_lua_loadbuffer = NULL;   /* loads the staged chunk */
static tolstring_t  g_lua_tolstring = NULL;    /* reads the chunk's status-string return */

/* lua-print sink pointers (existing discovered RVAs, no new discovery). Only
 * dereferenced when the sink is enabled; their absence is nonfatal (the sink
 * logs one warning and mod loading continues). */
static type_t         g_lua_type = NULL;
static pushcclosure_t g_lua_pushcclosure = NULL;
static setfield_t     g_lua_setfield = NULL;

static uint8_t   *g_module_base = NULL;      /* Darktide.exe base */
static HMODULE    g_hmodule = NULL;          /* this DLL's handle (self-locate mod_loader) */
static FILE      *g_log = NULL;
static lua_State *g_L = NULL;                /* the single captured VM */

/* ---- trampoline / hook state ----
 * Lua is single-threaded (the engine drives it on its main thread), so plain
 * volatile flags suffice. The re-entrancy guard `g_in_trampoline` is set
 * inside trampoline_run so the chunk's internal Lua pcall — which re-enters
 * our lua_pcall detour — skips the trampoline block and forwards straight to
 * the original, keeping the hook game-safe (no double-run, no counter
 * perturbation). The counters use Interlocked as the cheap Win32 idiom. */
static volatile LONG g_pcall_calls = 0;       /* observed pcall count (sanity/correlation) */
static volatile int  g_in_trampoline = 0;     /* re-entrancy guard for the trampoline chunk */

/* ---- Production trampoline state ----
 * The staged chunk (built once at worker startup from the two roots) and the
 * one-shot guard that fires it at pcall#1. Lua is single-threaded on the
 * engine's main thread, so these are only touched from that thread; the guard
 * is Interlocked anyway as the cheap Win32 one-shot idiom.
 *
 * Two roots:
 *   - MOD_LOADER_DIRNAME (mod_loader): the loader dir — where init.lua + its
 *     modules live. Runtime-controlled. SELF-LOCATED by the shell from its own
 *     DLL path (<dll-dir>\mod_loader, where the DLL ships next to the
 *     launcher). REQUIRED: if the DLL path can't be resolved, staging logs why
 *     and the trampoline is SKIPPED.
 *   - MOD_PATH_ENV (RELAY_MOD_PATH): the mod dir — where DMF + user mods +
 *     mods.lst live. User/mod-manager-controlled. OPTIONAL: if unset, the
 *     chunk emits an empty RELAY_MOD_PATH and mods just won't load.
 * The entry path = <dll-dir>\mod_loader\init.lua (joined + baked below). */
#define MOD_PATH_ENV         "RELAY_MOD_PATH"   /* mod root dir (user/mod-manager-controlled; optional) */
#define MOD_LOADER_DIRNAME   "mod_loader"            /* the loader dir, self-located next to the DLL */
#define MOD_LOADER_ENTRY     "init.lua"              /* the loader bootstrap entry */
static char            g_trampoline_chunk[4096];   /* NUL-terminated chunk; len 0 => not staged */
static size_t          g_trampoline_chunk_len = 0;
static volatile LONG   g_trampoline_done = 0;      /* one-shot: trampoline fired at pcall#1 */

/* ---- lua-print sink ----
 * Default-off opt-in: snapshot the exact RELAY_LUA_LOGS=1 once at worker
 * startup. When enabled and the required C-API pointers resolve, the trampoline
 * registers a private C callback as the temporary Lua global
 * __mod_relay_lua_log_sink (consumed by init.lua's wrapper in a later task).
 * This slice implements only the native callback + safe structured emission.
 * When disabled, nothing is published and there is no per-print cost. */
#define ENV_LUA_LOGS        "RELAY_LUA_LOGS"             /* exact value "1" enables */
#define LUA_LOG_SINK_GLOBAL "__mod_relay_lua_log_sink"   /* temp global set on the VM */
static int g_lua_log_sink_enabled = 0;   /* snapshot of RELAY_LUA_LOGS=1 at startup */

/* Serializes every relay_log physical-line emission (OutputDebugStringA + the
 * fputs/fflush pair) so worker-thread and Lua-thread (sink) lines never
 * interleave mid-line — this is the single logger-wide critical section.
 * SRWLOCK is zero-initialized ({0} == SRWLOCK_INIT), so no explicit init.
 * Acquired and released ONLY inside relay_log (one acquire, one release, no
 * early return between them). lua_log_sink_cb does NOT take this lock itself:
 * it reaches relay_log through the shell_log_sink_emit bridge, so holding this
 * non-reentrant SRWLOCK across that call would self-deadlock. */
static SRWLOCK g_log_lock = {0};

/* ---- structured logging ----
 * Every line: "<local ts+UTC offset> <LEVEL> <component>: <message>\n" to both
 * OutputDebugStringA and g_log. The timestamp is local time with an ISO-8601
 * UTC offset that follows the system time zone (e.g. 2026-07-16T12:34:56-04:00).
 * Levels filter via g_log_level (resolved once at worker startup from
 * RELAY_LOG_LEVEL; default INFO). The filter check happens BEFORE any
 * formatting/clock read, so filtered levels cost a single compare — important
 * since the pcall hook runs on the engine's Lua thread. */
enum { RELAY_LOG_ERROR = 1, RELAY_LOG_WARN = 2, RELAY_LOG_INFO = 3,
       RELAY_LOG_DEBUG = 4, RELAY_LOG_TRACE = 5 };
static int g_log_level = RELAY_LOG_INFO;

/* Case-insensitive ASCII equality (level names are ASCII; avoids a CRT
 * _stricmp dependency). */
static int log_name_ieq(const char *a, const char *b) {
    for (;;) {
        char ca = a[0], cb = b[0];
        if (ca >= 'a' && ca <= 'z') ca = (char)(ca - 32);
        if (cb >= 'a' && cb <= 'z') cb = (char)(cb - 32);
        if (ca != cb) return 0;
        if (ca == '\0') return 1;
        a++; b++;
    }
}

/* Resolve g_log_level from RELAY_LOG_LEVEL (case-insensitive name →
 * enum). Unset, overflow, or unknown name ⇒ INFO. */
static int resolve_log_level(void) {
    char buf[16];
    DWORD n = GetEnvironmentVariableA("RELAY_LOG_LEVEL", buf, sizeof(buf));
    if (n == 0 || n >= sizeof(buf)) return RELAY_LOG_INFO;
    if (log_name_ieq(buf, "error")) return RELAY_LOG_ERROR;
    if (log_name_ieq(buf, "warn"))  return RELAY_LOG_WARN;
    if (log_name_ieq(buf, "info"))  return RELAY_LOG_INFO;
    if (log_name_ieq(buf, "debug")) return RELAY_LOG_DEBUG;
    if (log_name_ieq(buf, "trace")) return RELAY_LOG_TRACE;
    return RELAY_LOG_INFO;
}

/* Returns 1 only if env_name is set to exactly "1" (byte-for-byte). Unset,
 * empty, "0", "true", whitespace, oversized, and all other values return 0.
 * This is the exact-match policy for the value-less RELAY_LUA_LOGS switch. */
static int env_is_exact_one(const char *env_name) {
    char buf[16];
    DWORD n = GetEnvironmentVariableA(env_name, buf, sizeof(buf));
    if (n == 0 || n >= sizeof(buf)) return 0;
    return strcmp(buf, "1") == 0 ? 1 : 0;
}

static void relay_log(int level, const char *component, const char *fmt, ...) {
    if (level > g_log_level) return;

    /* Local-time timestamp with ISO-8601 UTC offset: YYYY-MM-DDThh:mm:ss±HH:MM.
     * Wall clock is local (GetLocalTime); the offset follows the system time
     * zone. Windows defines UTC = local + bias, so the displayed offset (local
     * − UTC, in minutes) is −bias. Bias math (validated):
     *   EDT (Eastern, DST):     Bias=300, DaylightBias=−60  → bias= 240 → −04:00
     *   EST (Eastern, standard):Bias=300, StandardBias=0    → bias= 300 → −05:00
     *   CET (winter):           Bias=−60                    → bias= −60 → +01:00
     *   CEST (DST):             Bias=−60, DaylightBias=−60  → bias=−120 → +02:00
     *   UTC:                    Bias=0                      → bias=   0 → +00:00
     * The offset is always shown (UTC itself yields +00:00; no 'Z' special case). */
    SYSTEMTIME st;
    GetLocalTime(&st);
    TIME_ZONE_INFORMATION tzi;
    DWORD tzr = GetTimeZoneInformation(&tzi);
    LONG bias = (LONG)tzi.Bias;
    if (tzr == TIME_ZONE_ID_DAYLIGHT) bias += (LONG)tzi.DaylightBias;
    else                              bias += (LONG)tzi.StandardBias;
    int off_min = -bias;  /* local − UTC */
    char sign = (off_min >= 0) ? '+' : '-';
    int ah = abs(off_min) / 60;
    int am = abs(off_min) % 60;
    char ts[32];
    snprintf(ts, sizeof(ts), "%04d-%02d-%02dT%02d:%02d:%02d%c%02d:%02d",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
             sign, ah, am);

    /* Level name right-padded to 5 chars uppercase (keeps columns aligned). */
    const char *lname;
    switch (level) {
        case RELAY_LOG_ERROR: lname = "ERROR"; break;
        case RELAY_LOG_WARN:  lname = "WARN "; break;
        case RELAY_LOG_INFO:  lname = "INFO "; break;
        case RELAY_LOG_DEBUG: lname = "DEBUG"; break;
        case RELAY_LOG_TRACE: lname = "TRACE"; break;
        default:              lname = "?????"; break;
    }

    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    int mlen = vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    if (mlen < 0) return;

    /* fmt already ends in \n at every call site, so the line is terminated. */
    char line[1280];
    int n = snprintf(line, sizeof(line), "%s %s %s: %s", ts, lname, component, msg);
    if (n < 0) return;

    /* Emission critical section: serialize OutputDebugStringA + the file write
     * together under g_log_lock so concurrent callers (the worker thread and
     * the Lua-thread sink callback, both of which reach here) never interleave
     * a single physical line. All earlier work (level filter, timestamp, format)
     * runs lock-free on local buffers; the two format-error returns above happen
     * before the lock is taken, so no early-return path can leak it. The lock is
     * non-reentrant — lua_log_sink_cb intentionally does not hold it across the
     * relay_log call it makes via shell_log_sink_emit. */
    AcquireSRWLockExclusive(&g_log_lock);
    OutputDebugStringA(line);
    if (g_log) {
        fputs(line, g_log);
        fflush(g_log);
    }
    ReleaseSRWLockExclusive(&g_log_lock);
}

static void open_log(void) {
    char path[MAX_PATH];
    static const char logname[] = "relay.log";
    DWORD n = GetEnvironmentVariableA("RELAY_LOG_FILE", path, sizeof(path));
    if (n == 0 || n >= sizeof(path)) {
        /* default: beside the game exe. GetModuleFileNameA may fail (return 0)
         * or truncate (return >= sizeof(path)); in either case fall back to a
         * relative log name rather than using a bogus/truncated path. */
        DWORD m = GetModuleFileNameA(NULL, path, sizeof(path));
        char *slash = (m > 0 && m < sizeof(path)) ? strrchr(path, '\\') : NULL;
        if (slash && (size_t)(slash + 1 - path) + sizeof(logname) <= sizeof(path)) {
            strcpy(slash + 1, logname);
        } else {
            /* no separator, unresolvable path, or too long to append: fall
             * back to a relative log name in the current directory. */
            snprintf(path, sizeof(path), "%s", logname);
        }
    }
    /* "w" (not "a"): truncate so each game start gets a fresh log. The worker
     * opens the log once per game process (DllMain -> worker thread), so this
     * recreates the file on every launch — no unbounded growth across runs. */
    g_log = fopen(path, "w");
    relay_log(RELAY_LOG_INFO, "shell", "log -> %s\n", path);
}

/* ---- Production trampoline ----
 * The staging step self-locates the mod loader dir from this DLL's own path
 * (<dll-dir>\mod_loader), reads the mod dir (optional) from the child env,
 * joins the loader dir + init.lua into the entry path, and builds the chunk
 * once (worker startup); the run step executes it one-shot at pcall#1, BEFORE
 * g_orig_pcall, so it runs in the io/loadstring-present window (the engine
 * strips io/loadstring from globals between pcall #1 and #10). If the loader
 * dir can't be self-located, staging logs why and the run step logs SKIPPED at
 * pcall#1 — the game runs vanilla. */

/*
 * Self-locate the mod loader dir, join it + init.lua into the entry path, and
 * build g_trampoline_chunk. The loader dir is REQUIRED: on any failure (DLL
 * path unreadable/too long, no dir separator, join overflow, escape/overflow)
 * the chunk len stays 0 and trampoline_run will log SKIPPED. The mod dir
 * (RELAY_MOD_PATH) is OPTIONAL: unset/too long is logged and treated as
 * unset (mod_path = NULL -> the chunk emits an empty RELAY_MOD_PATH).
 * Idempotent: called once from the worker.
 */
static void trampoline_stage_chunk(void) {
    /* Mod loader root (self-located). The shell derives it from its own DLL
     * path: the DLL ships next to the launcher, and mod_loader/ ships next to
     * the DLL, so <dll-dir>\mod_loader is where init.lua + its modules live.
     * On any failure the chunk len stays 0 and trampoline_run logs SKIPPED. */
    char dll_path[1024];
    DWORD dn = GetModuleFileNameA(g_hmodule, dll_path, sizeof(dll_path));
    if (dn == 0) {
        relay_log(RELAY_LOG_INFO, "trampoline", "DLL self-path unreadable (lu=%lu); trampoline will be SKIPPED at pcall#1\n",
                  GetLastError());
        return;
    }
    if (dn >= sizeof(dll_path)) {
        relay_log(RELAY_LOG_INFO, "trampoline", "DLL self-path too long (%lu chars, max %zu); trampoline will be SKIPPED\n",
                  dn, sizeof(dll_path) - 1);
        return;
    }
    /* Strip the DLL filename at the last backslash -> the DLL directory. */
    char *slash = strrchr(dll_path, '\\');
    if (!slash) {
        relay_log(RELAY_LOG_INFO, "trampoline", "DLL self-path has no dir separator (%s); trampoline will be SKIPPED\n",
                  dll_path);
        return;
    }
    *slash = '\0';  /* dll_path is now the DLL directory */

    /* <dll-dir>\mod_loader — the loader root. */
    char mod_loader_dir[1024];
    int jn = trampoline_join_path(dll_path, MOD_LOADER_DIRNAME,
                                  mod_loader_dir, sizeof(mod_loader_dir));
    if (jn < 0) {
        relay_log(RELAY_LOG_INFO, "trampoline", "dll-dir+mod_loader join failed (overflow); trampoline will be SKIPPED\n");
        return;
    }

    /* Mod root (optional). Unset/too-long => NULL (the chunk emits an empty
     * RELAY_MOD_PATH; mods just won't load, the loader degrades gracefully). */
    char mod_dir[1024];
    const char *mod_path = NULL;
    DWORD mg = GetEnvironmentVariableA(MOD_PATH_ENV, mod_dir, sizeof(mod_dir));
    if (mg == 0) {
        DWORD e = GetLastError();
        if (e != ERROR_ENVVAR_NOT_FOUND) {
            relay_log(RELAY_LOG_INFO, "trampoline", "%s read error (lu=%lu); treating as unset\n",
                      MOD_PATH_ENV, e);
        }
    } else if (mg >= sizeof(mod_dir)) {
        relay_log(RELAY_LOG_INFO, "trampoline", "%s too long (%lu chars, max %zu); treating as unset\n",
                  MOD_PATH_ENV, mg, sizeof(mod_dir) - 1);
    } else {
        mod_path = mod_dir;
    }

    /* Join <mod_loader_dir> + init.lua into the production entry path
     * (Windows-canonical: exactly one backslash separator, idempotent on a
     * trailing separator). */
    char path[1024];
    int en = trampoline_join_path(mod_loader_dir, MOD_LOADER_ENTRY, path, sizeof(path));
    if (en < 0) {
        relay_log(RELAY_LOG_INFO, "trampoline", "mod_loader+entry join failed (overflow); trampoline will be SKIPPED\n");
        return;
    }

    int n = trampoline_build_chunk(mod_loader_dir, mod_path, path, RELAY_VERSION,
                                    g_trampoline_chunk, sizeof(g_trampoline_chunk));
    if (n < 0) {
        relay_log(RELAY_LOG_INFO, "trampoline", "chunk build failed (escape/overflow); trampoline will be SKIPPED\n");
        return;
    }
    g_trampoline_chunk_len = (size_t)n;
    relay_log(RELAY_LOG_INFO, "trampoline", "MOD_LOADER_DIR=%s\n", mod_loader_dir);
    if (mod_path) {
        relay_log(RELAY_LOG_INFO, "trampoline", "%s=%s\n", MOD_PATH_ENV, mod_path);
    } else {
        relay_log(RELAY_LOG_INFO, "trampoline", "%s unset (mods will not load)\n", MOD_PATH_ENV);
    }
    relay_log(RELAY_LOG_INFO, "trampoline", "entry path=%s\n", path);
    relay_log(RELAY_LOG_INFO, "trampoline", "chunk staged (%zu bytes); will run one-shot at pcall#1 (before orig pcall)\n",
              g_trampoline_chunk_len);
}

/* ---- lua-print sink callback + emission bridge ---- */

/* log_sink_render → relay_log bridge. log_sink_render has stripped every
 * CR/LF/NUL/control byte from the line, so this is safe format-string use: the
 * format string is a literal ("%.*s\n"), and `line` is only ever the %.*s data
 * argument — raw bytes can never become the format string, and any % in the
 * data is preserved as a literal byte by %.*s. Honors the explicit callback
 * length: log_sink_render guarantees `len` sanitized bytes with no embedded
 * NUL, and len <= LOG_SINK_LINE_BUDGET (768), so the int narrowing is safe and
 * the precision caps the write at exactly `len` (the contract's authoritative
 * boundary, not the incidental terminator). Runs under g_log_lock (taken per
 * line inside relay_log); `ud` is unused. */
static void shell_log_sink_emit(const char *line, size_t len, void *ud) {
    (void)ud;
    if (len > LOG_SINK_LINE_BUDGET) len = LOG_SINK_LINE_BUDGET;  /* defensive */
    relay_log(RELAY_LOG_INFO, "lua-print", "%.*s\n", (int)len, line);
}

/* The native callback published to Lua as __mod_relay_lua_log_sink. Expects
 * exactly one actual Lua string; uses lua_type (no hostile-value coercion — a
 * number/nil/table/extra-args call is ignored, not errored). Reads it with
 * lua_tolstring + explicit length, emits it through log_sink_render (which
 * splits/sanitizes into structured INFO lua-print lines), and returns zero
 * values. Never calls into Lua (no lua_error longjmp), never retains L or the
 * string (the pointer is only valid for the duration of the call). Does NOT
 * take g_log_lock itself: serialization happens per physical line inside
 * relay_log (reached via shell_log_sink_emit), and holding that non-reentrant
 * SRWLOCK across the call would self-deadlock. */
static int lua_log_sink_cb(lua_State *L) {
    if (g_lua_gettop(L) != 1 || g_lua_type(L, 1) != LUA_TSTRING) {
        return 0;  /* malformed call: wrong arg count or not a string */
    }
    size_t len = 0;
    const char *s = g_lua_tolstring(L, 1, &len);
    if (!s) return 0;  /* defensive: tolstring on a string should not fail */

    log_sink_render(s, len, shell_log_sink_emit, NULL);
    return 0;
}

/*
 * Execute the staged trampoline chunk on the engine's Lua thread at pcall#1.
 * Reads back the chunk's status-string return and logs it as
 *   [trampoline] @ pcall#1: <status>
 * Stack-clean (gettop saved / settop restored) and contained (lua_pcall returns
 * on error, never longjmps). See the file header's game-safety note.
 */
static void trampoline_run(lua_State *L) {
    g_in_trampoline = 1;
    relay_log(RELAY_LOG_INFO, "trampoline", "--- production trampoline @ pcall#1 ---\n");

    if (!g_orig_pcall || !g_lua_gettop || !g_lua_settop || !g_lua_tolstring || !g_lua_loadbuffer) {
        relay_log(RELAY_LOG_INFO, "trampoline", "@ pcall#1: SKIPPED (C-API not resolved)\n");
        g_in_trampoline = 0;
        return;
    }
    if (g_trampoline_chunk_len == 0) {
        /* staging already logged why (env var unset / too long / build fail). */
        relay_log(RELAY_LOG_INFO, "trampoline", "@ pcall#1: SKIPPED (chunk not staged — see startup log)\n");
        g_in_trampoline = 0;
        return;
    }

    int base = g_lua_gettop(L);

    /* Register the lua-print sink (when enabled) as the temporary Lua global
     * __mod_relay_lua_log_sink, BEFORE loading/running the chunk. The chunk's
     * init.lua is the consumer in a later task; this slice only publishes the
     * callback. Done before the chunk so the wrapper can rely on the global
     * existing from the loader's first instruction.
     *
     * Zero net stack effect (provably, against the grounded LuaJIT 2.1 ABI):
     * lua_pushcclosure(fn, 0) pushes exactly one value (the 0-upvalue closure),
     * and lua_setfield(L, LUA_GLOBALSINDEX, k) pops exactly that one value
     * (setfield does globals[k] = top-of-stack; pop). So +1 -1 = 0, and the
     * chunk load below still sees the stack at `base`.
     *
     * If a required C-API pointer is unavailable (defensive — these RVAs are
     * always in the canonical table), log one warning and continue; mod loading
     * must never depend on the optional print sink. tolstring + gettop are
     * already guaranteed non-NULL by the trampoline_run guard above. */
    if (g_lua_log_sink_enabled) {
        if (g_lua_pushcclosure && g_lua_setfield && g_lua_type) {
            g_lua_pushcclosure(L, &lua_log_sink_cb, 0);
            g_lua_setfield(L, LUA_GLOBALSINDEX, LUA_LOG_SINK_GLOBAL);
            /* Component is "trampoline", not "lua-print": this is the pcall#1
             * setup step (plumbing), not a captured Lua line — "lua-print" is
             * reserved for captured print output emitted via the sink. */
            relay_log(RELAY_LOG_INFO, "trampoline",
                      "lua-print sink registered as global %s\n",
                      LUA_LOG_SINK_GLOBAL);
        } else {
            relay_log(RELAY_LOG_WARN, "trampoline",
                      "lua-print sink not registered: a required C-API pointer "
                      "is NULL (pushcclosure/setfield/type); lua-print disabled "
                      "this run\n");
        }
    }

    /* Load the chunk (pushes a function at base+1). On parse failure the error
     * message is on top; log it and bail with a clean stack. */
    int rc = g_lua_loadbuffer(L, g_trampoline_chunk, g_trampoline_chunk_len, "relay_trampoline");
    if (rc != 0) {
        const char *e = g_lua_tolstring(L, -1, NULL);
        relay_log(RELAY_LOG_ERROR, "trampoline", "CHUNK LOAD FAILED (rc=%d): %s\n", rc, e ? e : "<no msg>");
        g_lua_settop(L, base);
        g_in_trampoline = 0;
        return;
    }

    /* Run the chunk: 0 args, 1 result, no errfunc. pcall RETURNS on error
     * (never longjmps), so the chunk is fully contained. On success the status
     * string is at base+1. The chunk's internal Lua pcall(fn) re-enters our
     * lua_pcall hook, but g_in_trampoline=1 makes detour_pcall skip its
     * trampoline block and forward — so it does not perturb the counter or
     * re-run the trampoline. */
    int prc = g_orig_pcall(L, 0, 1, 0);
    if (prc != 0) {
        const char *e = g_lua_tolstring(L, -1, NULL);
        relay_log(RELAY_LOG_ERROR, "trampoline", "CHUNK PCALL FAILED (rc=%d): %s\n", prc, e ? e : "<no msg>");
        relay_log(RELAY_LOG_ERROR, "trampoline", "  (the chunk itself errored before returning a status string)\n");
        g_lua_settop(L, base);
        g_in_trampoline = 0;
        return;
    }

    /* Read + log the status string. The chunk always returns a string ("OK" or
     * "FAIL <step>: <err>"); lua_tolstring returns NULL only if the top value
     * isn't a string/number — defensive. */
    size_t len = 0;
    const char *status = g_lua_tolstring(L, -1, &len);
    relay_log(RELAY_LOG_INFO, "trampoline", "@ pcall#1: %s\n", status ? status : "<null status>");

    g_lua_settop(L, base);  /* pop the status string — restore engine stack */
    g_in_trampoline = 0;
}

/* ---- lifecycle detours ---- */

/* lua_newstate — capture the single Lua VM + one-time structural sanity log.
 * VM is fresh here (no stdlib/globals yet). lua_gettop(L) on a fresh state
 * must return 0, confirming the LJ_64 non-GC64 struct layout in-process. */
static lua_State *detour_newstate(lua_Alloc f, void *ud) {
    lua_State *L = g_orig_newstate(f, ud);
    if (L) {
        relay_log(RELAY_LOG_INFO, "shell", "lua_newstate hook fired; L = %p\n", (void *)L);
        if (!g_L) g_L = L;
        if (g_lua_gettop) {
            int top = g_lua_gettop(L);
            relay_log(RELAY_LOG_INFO, "shell", "lua_gettop(L) = %d (expect 0 for fresh state)\n", top);
        }
    } else {
        relay_log(RELAY_LOG_ERROR, "shell", "lua_newstate returned NULL\n");
    }
    return L;
}

/* lua_pcall — count calls + run the staged trampoline one-shot at pcall#1
 * BEFORE the original pcall (so the chunk runs in the io/loadstring-present
 * window). The chunk's own internal pcall re-enters here but is skipped by
 * g_in_trampoline (forward-only) — no re-run, no counter perturbation. */
static int detour_pcall(lua_State *L, int nargs, int nresults, int errfunc) {
    if (!g_in_trampoline) {
        LONG n = InterlockedIncrement(&g_pcall_calls);
        if (!g_L) g_L = L;

        /* Production trampoline — one-shot at pcall#1, BEFORE the engine's
         * pcall, so it runs while io/loadstring are still present (they are
         * stripped between pcall #1 and #10). Runs first so its result is the
         * headline of the pcall#1 log block. */
        if (n == 1 && InterlockedCompareExchange(&g_trampoline_done, 1, 0) == 0) {
            trampoline_run(L);
        }
    }
    return g_orig_pcall(L, nargs, nresults, errfunc);
}

/* Create + enable a MinHook detour. Returns 1 on success, 0 on failure. */
static int install_hook(void *target, void *detour, void **original, const char *name) {
    MH_STATUS mh = MH_CreateHook(target, detour, original);
    if (mh != MH_OK) {
        relay_log(RELAY_LOG_ERROR, "shell", "MH_CreateHook(%s) failed: %d\n", name, mh);
        return 0;
    }
    mh = MH_EnableHook(target);
    if (mh != MH_OK) {
        relay_log(RELAY_LOG_ERROR, "shell", "MH_EnableHook(%s) failed: %d\n", name, mh);
        return 0;
    }
    relay_log(RELAY_LOG_INFO, "shell", "hook installed: %s at %p (detour %p)\n", name, target, detour);
    return 1;
}

/* ---- worker: seam call + hook install ---- */
static DWORD WINAPI worker(LPVOID arg) {
    (void)arg;
    g_log_level = resolve_log_level();
    g_lua_log_sink_enabled = env_is_exact_one(ENV_LUA_LOGS);
    open_log();
    relay_log(RELAY_LOG_INFO, "shell", "=== DllMain worker started (pid=%lu) ===\n", GetCurrentProcessId());

    if (g_lua_log_sink_enabled) {
        relay_log(RELAY_LOG_INFO, "shell", "lua-print sink enabled (RELAY_LUA_LOGS=1)\n");
    }

    /* The host process command line as the game sees it — the authoritative
     * child-side view of what the launcher built: the quoted exe + the
     * forwarded game arguments (e.g. "...Darktide.exe" --lua-heap-mb-size 2048).
     * Lets the operator confirm exactly what args reached the game. */
    relay_log(RELAY_LOG_INFO, "shell", "launching %s\n",
              GetCommandLineA() ? GetCommandLineA() : "");

    HMODULE h = GetModuleHandleW(NULL);  /* Darktide.exe */
    if (!h) { relay_log(RELAY_LOG_ERROR, "shell", "FATAL: GetModuleHandle(NULL) failed\n"); return 1; }
    MODULEINFO mi;
    if (!GetModuleInformation(GetCurrentProcess(), h, &mi, sizeof(mi))) {
        relay_log(RELAY_LOG_ERROR, "shell", "FATAL: GetModuleInformation failed (lu=%lu)\n", GetLastError());
        return 1;
    }
    g_module_base = (uint8_t *)h;
    relay_log(RELAY_LOG_INFO, "shell", "module base = %p, SizeOfImage = 0x%lx\n",
         (void *)g_module_base, (unsigned long)mi.SizeOfImage);

    /* Invoke the Rust discovery seam in-process. Resolves the LuaJIT/engine
     * function addresses (the canonical 16 + the validated engine anchors). */
    RelayAddressTable tbl;
    uint8_t detail[256] = {0};
    int rc = relay_discover_detail(g_module_base, mi.SizeOfImage, &tbl,
                                       detail, sizeof(detail));
    if (rc != RELAY_OK) {
        relay_log(RELAY_LOG_ERROR, "shell", "FATAL: relay_discover rc=%d (%s)\n", rc, (char*)detail);
        return 1;
    }
    relay_log(RELAY_LOG_INFO, "discovery", "discovery OK. resolved addresses (RVAs):\n");
    relay_log(RELAY_LOG_DEBUG, "discovery", "  lua_newstate_thunk  = 0x%08x  body=0x%08x\n",
         tbl.lua_newstate_thunk, tbl.lua_newstate_body);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  lua_atpanic=0x%08x  lua_gettop=0x%08x\n",
         tbl.lua_atpanic, tbl.lua_gettop);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  lua_pcall=0x%08x  luaL_loadbuffer=0x%08x\n",
         tbl.lua_pcall, tbl.lual_loadbuffer);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  lua_pushcclosure=0x%08x  lua_setfield=0x%08x\n",
         tbl.lua_pushcclosure, tbl.lua_setfield);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  lua_pushstring=0x%08x  lua_tolstring=0x%08x\n",
         tbl.lua_pushstring, tbl.lua_tolstring);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  lua_createtable=0x%08x  lua_type=0x%08x\n",
         tbl.lua_createtable, tbl.lua_type);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  lua_tonumber=0x%08x  lua_settop=0x%08x\n",
         tbl.lua_tonumber, tbl.lua_settop);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  luaL_openlibs=0x%08x  lua_panic_body=0x%08x\n",
         tbl.lual_openlibs, tbl.lua_panic_body);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  LuaEnvironment::init = 0x%08x..0x%08x\n",
         tbl.luaenvironment_init_begin, tbl.luaenvironment_init_end);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  lua_getfield=0x%08x  lua_resource::bytecode=0x%08x\n",
         tbl.lua_getfield, tbl.lua_resource_bytecode);
    relay_log(RELAY_LOG_DEBUG, "discovery", "  lua_getfenv=0x%08x  lua_setfenv=0x%08x\n",
         tbl.lua_getfenv, tbl.lua_setfenv);

    /* Resolve the LuaJIT C-API pointers the production trampoline consumes.
     * The other discovered anchors stay in the table (ABI-stable) but are not
     * dereferenced here. */
    g_lua_gettop     = (gettop_t)(g_module_base + tbl.lua_gettop);
    g_lua_settop     = (settop_t)(g_module_base + tbl.lua_settop);
    g_lua_loadbuffer = (loadbuffer_t)(g_module_base + tbl.lual_loadbuffer);
    g_lua_tolstring  = (tolstring_t)(g_module_base + tbl.lua_tolstring);

    /* lua-print sink pointers: existing discovered RVAs (no new discovery).
     * Only dereferenced when the sink is enabled; resolved unconditionally so
     * the registration check is a simple NULL test. */
    g_lua_type         = (type_t)(g_module_base + tbl.lua_type);
    g_lua_pushcclosure = (pushcclosure_t)(g_module_base + tbl.lua_pushcclosure);
    g_lua_setfield     = (setfield_t)(g_module_base + tbl.lua_setfield);

    /* Install the two production hooks. Both are required/fatal: without
     * lua_newstate the Lua state is never captured, and without lua_pcall the
     * trampoline never runs. A failure logs FATAL and the worker exits (the
     * launcher's hook-ready wait then times out and terminates the game rather
     * than resuming half-modded). */
    MH_STATUS mh = MH_Initialize();
    if (mh != MH_OK) { relay_log(RELAY_LOG_ERROR, "shell", "FATAL: MH_Initialize failed: %d\n", mh); return 1; }
    if (!install_hook((void *)(g_module_base + tbl.lua_newstate_thunk),
                      (void *)&detour_newstate, (void **)&g_orig_newstate, "lua_newstate")) {
        return 1;
    }
    if (!install_hook((void *)(g_module_base + tbl.lua_pcall),
                      (void *)&detour_pcall, (void **)&g_orig_pcall, "lua_pcall")) {
        return 1;
    }
    relay_log(RELAY_LOG_INFO, "shell", "production hooks armed: lua_newstate (VM capture) + lua_pcall (trampoline @ pcall#1)\n");

    /* Production trampoline: stage the chunk now (self-locating the mod loader
     * dir from this DLL's path + reading RELAY_MOD_PATH for the mod root) so
     * it is ready to fire one-shot at pcall#1 (the hooks above are armed and
     * the engine's first lua_pcall is imminent once the main thread resumes). */
    trampoline_stage_chunk();

    /* Production hook-ready handshake: signal the launcher that the hooks are
     * enabled so it can resume the main thread. The launcher creates the
     * named event before injection and waits on it before ResumeThread;
     * resuming earlier loses the lua_newstate hook (the engine calls
     * lua_newstate during startup). If the event can't be opened (e.g.
     * launcher didn't create it), log and continue — the hooks are still armed. */
    HANDLE ready = OpenEventA(EVENT_MODIFY_STATE, FALSE, RELAY_HOOK_READY_EVENT);
    if (ready) {
        SetEvent(ready);
        CloseHandle(ready);
        relay_log(RELAY_LOG_INFO, "shell", "hook-ready signaled (%s)\n", RELAY_HOOK_READY_EVENT);
    } else {
        relay_log(RELAY_LOG_WARN, "shell", "OpenEvent(%s) failed (lu=%lu); hooks armed, not signaled\n",
             RELAY_HOOK_READY_EVENT, GetLastError());
    }

    relay_log(RELAY_LOG_INFO, "shell", "worker complete; waiting for the engine lifecycle...\n");
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_hmodule = hinst;  /* self-locate mod_loader from the DLL's own path */
        DisableThreadLibraryCalls(hinst);
        /* Run on a worker so DllMain returns promptly (the loader holds the
         * loader lock; discovery + hook install must not block on it). */
        HANDLE h = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (h) CloseHandle(h);
    }
    return TRUE;
}
