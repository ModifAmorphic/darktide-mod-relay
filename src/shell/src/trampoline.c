/*
 * trampoline.c — pure helpers for the production trampoline.
 *
 * Implementation of the helpers declared in trampoline.h. This file has NO
 * Windows, Lua, or hook dependencies — only string ops — so it compiles
 * directly into both the shell DLL and the C unit-test exes. The trampoline's
 * game-safety and two-roots contracts are normative in
 * docs/reference/relay/shell.md.
 */
#include "trampoline.h"

#include <stdio.h>
#include <string.h>

/* The trampoline chunk template. The five `%s` receive, in order: the escaped
 * mod loader root, the escaped mod root (empty string when unset), the version
 * assignment value (a quoted escaped string or nil), the splash-skip token
 * (literal "1" or "", not escaped), and the escaped entry-file path — each
 * becomes an internal bootstrap global (see trampoline.h). Step order is
 * io.open -> read -> loadstring -> run, guarded at each step except f:read, so
 * a read error is the one unguarded failure and surfaces as CHUNK PCALL FAILED
 * (caught by the outer pcall in trampoline_run). */
static const char TRAMPOLINE_CHUNK_FMT[] =
    "MOD_LOADER_DIR = \"%s\"\n"
    "RELAY_MOD_PATH = \"%s\"\n"
    "MOD_RELAY_VERSION = %s\n"
    "RELAY_SKIP_SPLASH = \"%s\"\n"
    "local f, err = io.open(\"%s\", \"r\")\n"
    "if not f then return \"FAIL io.open: \" .. tostring(err) end\n"
    "local data = f:read(\"*all\"); f:close()\n"
    "local fn, lerr = loadstring(data)\n"
    "if not fn then return \"FAIL loadstring: \" .. tostring(lerr) end\n"
    "local ok, rerr = pcall(fn)\n"
    "if not ok then return \"FAIL run: \" .. tostring(rerr) end\n"
    "return \"OK\"\n";

int trampoline_escape_path(const char *path, size_t path_len,
                           char *out, size_t out_cap) {
    if (!path || !out || out_cap == 0) return -1;
    size_t off = 0;
    for (size_t i = 0; i < path_len; i++) {
        char c = path[i];
        size_t need = (c == '\\' || c == '"') ? 2 : 1;
        if (off + need + 1 > out_cap) return -1;  /* +1 for the NUL */
        if (c == '\\' || c == '"') out[off++] = '\\';
        out[off++] = c;
    }
    out[off] = '\0';
    return (int)off;
}

int trampoline_build_chunk(const char *mod_loader_dir, const char *mod_path,
                           const char *entry_path, const char *relay_version,
                           int skip_splash,
                           char *out, size_t out_cap) {
    if (!mod_loader_dir || !entry_path || !out || out_cap == 0) return -1;
    size_t loader_len = strlen(mod_loader_dir);
    size_t entry_len = strlen(entry_path);
    if (loader_len == 0 || entry_len == 0) return -1;  /* empty is a misconfig */

    /* Escape the mod loader root + the entry path for a Lua double-quoted string. */
    char esc_loader[2048];
    int ln = trampoline_escape_path(mod_loader_dir, loader_len,
                                    esc_loader, sizeof(esc_loader));
    if (ln < 0) return -1;

    char esc_entry[2048];
    int xn = trampoline_escape_path(entry_path, entry_len, esc_entry, sizeof(esc_entry));
    if (xn < 0) return -1;

    /* The mod root is optional: NULL/empty yields the empty-string global so
     * the loader treats it as "no mods" gracefully. */
    char esc_mod[2048];
    esc_mod[0] = '\0';
    if (mod_path && mod_path[0] != '\0') {
        int mn = trampoline_escape_path(mod_path, strlen(mod_path),
                                        esc_mod, sizeof(esc_mod));
        if (mn < 0) return -1;
    }

    /* Product-version handoff is deliberately non-fatal. The 256-byte input
     * ceiling is only a bounded C transport limit; Lua applies the tighter
     * 128-byte metadata policy. The fixed escape/output buffers keep stack use
     * bounded, and a control-heavy value that cannot fit fails safely to nil.
     * Control bytes are decimal-escaped so Lua can reject the original bytes. */
    char version_value[768];
    strcpy(version_value, "nil");
    if (relay_version && relay_version[0] != '\0') {
        size_t vn = strlen(relay_version);
        if (vn <= 256) {
            char escaped[700];
            size_t off = 0;
            int valid = 1;
            for (size_t i = 0; i < vn; i++) {
                unsigned char c = (unsigned char)relay_version[i];
                if (c == '\\' || c == '"') {
                    if (off + 2 >= sizeof(escaped)) { valid = 0; break; }
                    escaped[off++] = '\\';
                    escaped[off++] = (char)c;
                } else if (c < 0x20 || c == 0x7f) {
                    if (off + 4 >= sizeof(escaped)) { valid = 0; break; }
                    int written = snprintf(escaped + off, sizeof(escaped) - off,
                                           "\\%03u", (unsigned)c);
                    if (written != 4) { valid = 0; break; }
                    off += 4;
                } else {
                    if (off + 1 >= sizeof(escaped)) { valid = 0; break; }
                    escaped[off++] = (char)c;
                }
            }
            if (valid) {
                escaped[off] = '\0';
                int written = snprintf(version_value, sizeof(version_value),
                                       "\"%s\"", escaped);
                if (written < 0 || (size_t)written >= sizeof(version_value)) {
                    strcpy(version_value, "nil");
                }
            }
        }
    }

    int n = snprintf(out, out_cap, TRAMPOLINE_CHUNK_FMT,
                     esc_loader, esc_mod, version_value,
                     skip_splash ? "1" : "",
                     esc_entry);
    if (n < 0 || (size_t)n >= out_cap) return -1;  /* encoding error or overflow */
    return n;
}

int trampoline_join_path(const char *dir, const char *name,
                         char *out, size_t out_cap) {
    if (!dir || !name || !out || out_cap == 0) return -1;
    size_t dlen = strlen(dir);
    size_t nlen = strlen(name);
    if (dlen == 0 || nlen == 0) return -1;  /* empty dir/name is a misconfig */

    /* Exactly one separator: skip it if `dir` already ends in one. Backslash is
     * the canonical Windows form (also accepted by Proton); a trailing forward
     * slash is tolerated as an already-present separator. */
    int has_sep = (dir[dlen - 1] == '\\' || dir[dlen - 1] == '/');
    size_t need = dlen + (has_sep ? 0 : 1) + nlen;
    if (need + 1 > out_cap) return -1;  /* +1 for the NUL */

    size_t off = 0;
    memcpy(out + off, dir, dlen);   off += dlen;
    if (!has_sep) out[off++] = '\\';
    memcpy(out + off, name, nlen);  off += nlen;
    out[off] = '\0';
    return (int)off;
}
