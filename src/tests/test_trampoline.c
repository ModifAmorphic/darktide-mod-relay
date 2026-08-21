/*
 * test_trampoline.c — Unit tests for the production trampoline pure helpers.
 *
 * Covers trampoline_escape_path (the Windows-path -> Lua-string escape),
 * trampoline_path_has_control (the shell env gate's control-byte scan), and
 * trampoline_build_chunk (the full chunk assembly). These run via wine like
 * the other C tests; they compile trampoline.c directly (no Lua/Windows deps).
 */
#include "test_runner.h"
#include "../shell/src/trampoline.c"  /* compile the pure impl directly */
#include <stdio.h>
#include <string.h>

#ifndef RELAY_VERSION
#define RELAY_VERSION "0.0.0-dev"
#endif

/* ---- trampoline_escape_path ---- */

void test_escape_plain_path(void) {
    char out[64];
    int n = trampoline_escape_path("C:/tmp/x.lua", 12, out, sizeof(out));
    ASSERT_EQ(12, n);
    ASSERT_STREQ("C:/tmp/x.lua", out);  /* forward slashes unchanged */
}

void test_escape_backslashes_doubled(void) {
    /* Windows path: every backslash doubles in a Lua double-quoted string. */
    char out[64];
    int n = trampoline_escape_path("Z:\\foo\\bar.lua", 14, out, sizeof(out));
    ASSERT_EQ(16, n);  /* 14 + 2 extra (two backslashes doubled) */
    ASSERT_STREQ("Z:\\\\foo\\\\bar.lua", out);
}

void test_escape_quote_doubled(void) {
    char out[64];
    int n = trampoline_escape_path("a\"b", 3, out, sizeof(out));
    ASSERT_EQ(4, n);
    ASSERT_STREQ("a\\\"b", out);
}

void test_escape_empty_path(void) {
    char out[8];
    int n = trampoline_escape_path("", 0, out, sizeof(out));
    ASSERT_EQ(0, n);
    ASSERT_STREQ("", out);
}

void test_escape_overflow_returns_neg1(void) {
    /* 2 backslashes -> 4 escaped bytes + NUL = 5; cap of 4 must reject. */
    char out[4];
    int n = trampoline_escape_path("\\\\", 2, out, sizeof(out));
    ASSERT_EQ(-1, n);
}

void test_escape_null_args(void) {
    char out[8];
    ASSERT_EQ(-1, trampoline_escape_path(NULL, 0, out, sizeof(out)));
    ASSERT_EQ(-1, trampoline_escape_path("a", 1, NULL, sizeof(out)));
    ASSERT_EQ(-1, trampoline_escape_path("a", 1, out, 0));
}

/* ---- trampoline_path_has_control ---- */

void test_has_control_clean_paths(void) {
    /* Plain ASCII paths (with the escapable bytes) contain no control chars. */
    ASSERT_EQ(0, trampoline_path_has_control("C:\\mods\\alt mgr.lua", 19));
    ASSERT_EQ(0, trampoline_path_has_control("", 0));
    /* High bytes (ANSI codepage path characters) are NOT control chars. */
    ASSERT_EQ(0, trampoline_path_has_control("C:\\m\xeb\xd6ner.lua", 13));
}

void test_has_control_detects_control_bytes(void) {
    /* Every control byte must be detected: 0x00-0x1F and 0x7F. The env gate
     * relies on this: escape_path only handles backslash + double-quote, so a
     * raw control byte would corrupt the staged chunk's Lua string literal. */
    for (unsigned c = 0; c < 0x20; c++) {
        char one[1] = { (char)c };
        if (trampoline_path_has_control(one, 1) != 1) {
            ASSERT_FAIL("byte 0x%02x should be a control char", c);
        }
    }
    ASSERT_EQ(1, trampoline_path_has_control("\x7f", 1));
    /* A newline embedded mid-path — the direct-injection case. */
    ASSERT_EQ(1, trampoline_path_has_control("C:\\alt\nmgr.lua", 14));
    /* The byte just outside the range (0x20 space, 0x7e tilde) passes. */
    ASSERT_EQ(0, trampoline_path_has_control(" ", 1));
    ASSERT_EQ(0, trampoline_path_has_control("~", 1));
}

void test_has_control_null_is_clean(void) {
    ASSERT_EQ(0, trampoline_path_has_control(NULL, 4));
}

/* ---- trampoline_build_chunk ---- */

void test_build_chunk_sets_both_path_globals_and_opens_entry(void) {
    /* The chunk sets MOD_LOADER_DIR (escaped loader root) +
     * RELAY_MOD_PATH (escaped mod root), then opens the entry file (escaped
     * joined path). All three must appear. Splash disabled (the default in
     * existing tests) emits RELAY_SKIP_SPLASH = "" and the launcher-derived
     * mods-in-game-tree hint disabled emits RELAY_MODS_IN_GAME_TREE = "".
     * A NULL manager (unset) emits RELAY_MOD_MANAGER = "" — the unset
     * default must not perturb the other globals. */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", "0.3.0-beta.2",
                                   0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);

    /* Loader-root global (MOD_LOADER_DIR — internal, trampoline-set), escaped. */
    ASSERT_NOTNULL(strstr(out, "MOD_LOADER_DIR = \"Z:\\\\mod_loader\""));
    /* Mod-root global, escaped. */
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"Z:\\\\mods\""));
    /* Manager global, unset (NULL) -> empty string. */
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_MANAGER = \"\""));
    ASSERT_NOTNULL(strstr(out, "MOD_RELAY_VERSION = \"0.3.0-beta.2\""));
    /* Splash-skip global, disabled (empty string). */
    ASSERT_NOTNULL(strstr(out, "RELAY_SKIP_SPLASH = \"\""));
    /* Mods-in-game-tree hint global, disabled (empty string). */
    ASSERT_NOTNULL(strstr(out, "RELAY_MODS_IN_GAME_TREE = \"\""));
    /* Entry path baked into io.open(...), escaped. */
    ASSERT_NOTNULL(strstr(out, "io.open(\"Z:\\\\mod_loader\\\\t.lua\", \"r\")"));
    /* Each FAIL step label is present (defines the status vocabulary). */
    ASSERT_NOTNULL(strstr(out, "FAIL io.open:"));
    ASSERT_NOTNULL(strstr(out, "FAIL loadstring:"));
    ASSERT_NOTNULL(strstr(out, "FAIL run:"));
    /* Success path returns OK. */
    ASSERT_NOTNULL(strstr(out, "return \"OK\""));
}

void test_build_chunk_plain_paths(void) {
    /* Forward-slash roots + entry need no escaping. */
    char out[1024];
    int n = trampoline_build_chunk("/mod_loader", "/mods", NULL, "/mod_loader/x.lua", "0.2.0",
                                    0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "MOD_LOADER_DIR = \"/mod_loader\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"/mods\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_SKIP_SPLASH = \"\""));
    ASSERT_NOTNULL(strstr(out, "io.open(\"/mod_loader/x.lua\", \"r\")"));
}

void test_build_chunk_null_mod_path_emits_empty_global(void) {
    /* mod_path NULL is the "no mods" case: the chunk emits RELAY_MOD_PATH = ""
     * and is still valid (entry loads from the loader root). */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", NULL, NULL,
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "MOD_LOADER_DIR = \"Z:\\\\mod_loader\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"\""));
    ASSERT_NOTNULL(strstr(out, "io.open(\"Z:\\\\mod_loader\\\\t.lua\", \"r\")"));
}

void test_build_chunk_empty_mod_path_emits_empty_global(void) {
    /* An empty-string mod path is treated the same as NULL (no mods). */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "", NULL,
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"\""));
}

void test_build_chunk_mod_manager_set_emits_escaped_global(void) {
    /* A set manager path is baked verbatim, escaped for a Lua double-quoted
     * string (backslashes doubled), independently of the mod path. */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods",
                                   "Z:\\tools\\alt manager.exe",
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_MANAGER = \"Z:\\\\tools\\\\alt manager.exe\""));
    /* The other globals are unaffected by the manager being set. */
    ASSERT_NOTNULL(strstr(out, "MOD_LOADER_DIR = \"Z:\\\\mod_loader\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"Z:\\\\mods\""));
    ASSERT_NOTNULL(strstr(out, "io.open(\"Z:\\\\mod_loader\\\\t.lua\", \"r\")"));
}

void test_build_chunk_mod_manager_quote_is_escaped(void) {
    /* A quote in the manager path must be doubled so the Lua parser yields
     * the original byte. */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods",
                                   "Z:\\a\"b\\mgr.exe",
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_MANAGER = \"Z:\\\\a\\\"b\\\\mgr.exe\""));
}

void test_build_chunk_null_mod_manager_emits_empty_global(void) {
    /* Manager NULL is the "no alternate manager" case: the chunk emits
     * RELAY_MOD_MANAGER = "" and everything else is unchanged. */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_MANAGER = \"\""));
}

void test_build_chunk_empty_mod_manager_emits_empty_global(void) {
    /* An empty-string manager path is treated the same as NULL. */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", "",
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_MANAGER = \"\""));
}

void test_build_chunk_mod_manager_set_with_null_mod_path(void) {
    /* The two optional paths are independent: a set manager must not resurrect
     * an unset mod path (and vice versa). */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", NULL,
                                   "Z:\\tools\\mgr.exe",
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_MANAGER = \"Z:\\\\tools\\\\mgr.exe\""));
}

void test_build_chunk_null_version_emits_nil_without_skipping_loader(void) {
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", NULL, 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "MOD_RELAY_VERSION = nil"));
    ASSERT_NOTNULL(strstr(out, "io.open(\"Z:\\\\mod_loader\\\\t.lua\", \"r\")"));
}

void test_build_chunk_empty_version_emits_nil(void) {
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", "", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "MOD_RELAY_VERSION = nil"));
}

void test_build_chunk_version_is_lua_escaped(void) {
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", "1.2\\\"x\ny",
                                   0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "MOD_RELAY_VERSION = \"1.2\\\\\\\"x\\010y\""));
}

void test_build_chunk_overlong_version_emits_nil_without_skipping_loader(void) {
    char version[258];
    memset(version, 'x', sizeof(version) - 1);
    version[sizeof(version) - 1] = '\0';
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", version,
                                   0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "MOD_RELAY_VERSION = nil"));
    ASSERT_NOTNULL(strstr(out, "return \"OK\""));
}

void test_build_chunk_hands_off_exact_compiled_product_version(void) {
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", RELAY_VERSION,
                                   0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    char expected[384];
    int en = snprintf(expected, sizeof(expected),
                      "MOD_RELAY_VERSION = \"%s\"", RELAY_VERSION);
    ASSERT_TRUE(en > 0 && (size_t)en < sizeof(expected));
    ASSERT_NOTNULL(strstr(out, expected));
}

void test_build_chunk_empty_loader_dir_rejected(void) {
    char out[64];
    ASSERT_EQ(-1, trampoline_build_chunk("", "Z:\\mods", NULL, "Z:\\t.lua", "0.2.0", 0, 0, out, sizeof(out)));
}

void test_build_chunk_empty_entry_rejected(void) {
    char out[64];
    ASSERT_EQ(-1, trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL, "", "0.2.0", 0, 0, out, sizeof(out)));
}

void test_build_chunk_null_args(void) {
    char out[64];
    /* mod_loader_dir NULL -> rejected. */
    ASSERT_EQ(-1, trampoline_build_chunk(NULL, "Z:\\mods", NULL, "Z:\\t.lua", "0.2.0", 0, 0, out, sizeof(out)));
    /* entry_path NULL -> rejected. */
    ASSERT_EQ(-1, trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL, NULL, "0.2.0", 0, 0, out, sizeof(out)));
    /* out NULL -> rejected. */
    ASSERT_EQ(-1, trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL, "Z:\\t.lua", "0.2.0", 0, 0, NULL, sizeof(out)));
    /* zero cap -> rejected. */
    ASSERT_EQ(-1, trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL, "Z:\\t.lua", "0.2.0", 0, 0, out, 0));
    /* (mod_path/mod_manager NULL is NOT an error — covered by the
     * empty-global tests.) */
}

void test_build_chunk_overflow(void) {
    /* A tiny buffer cannot hold the chunk -> reject, no partial write relied on. */
    char out[8];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_EQ(-1, n);
}

void test_build_chunk_round_trips_long_paths(void) {
    /* Realistically long Windows roots + entry still fit the default cap. */
    const char *loader = "Z:\\very\\deep\\path\\to\\the\\mod_loader\\root";
    const char *mods   = "Z:\\very\\deep\\path\\to\\the\\user\\mods\\dir";
    const char *entry  = "Z:\\very\\deep\\path\\to\\the\\mod_loader\\root\\file.lua";
    char out[1024];
    int n = trampoline_build_chunk(loader, mods, NULL, entry, "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    /* Every backslash in the original is doubled in the baked chunk. */
    ASSERT_NOTNULL(strstr(out, "Z:\\\\very\\\\deep\\\\path"));
}

void test_build_chunk_skip_splash_enabled_emits_one(void) {
    /* When skip_splash is 1 (truthy), the chunk emits RELAY_SKIP_SPLASH = "1". */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 1, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_SKIP_SPLASH = \"1\""));
    /* The disabled form must NOT appear. */
    ASSERT_TRUE(strstr(out, "RELAY_SKIP_SPLASH = \"\"") == NULL);
    /* The other globals are unaffected by the splash flag. */
    ASSERT_NOTNULL(strstr(out, "MOD_LOADER_DIR = \"Z:\\\\mod_loader\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"Z:\\\\mods\""));
    ASSERT_NOTNULL(strstr(out, "io.open(\"Z:\\\\mod_loader\\\\t.lua\", \"r\")"));
}

void test_build_chunk_mods_in_game_tree_enabled_emits_one(void) {
    /* When mods_in_game_tree is 1 (truthy), the chunk emits
     * RELAY_MODS_IN_GAME_TREE = "1". */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 1, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_MODS_IN_GAME_TREE = \"1\""));
    /* The disabled form must NOT appear. */
    ASSERT_TRUE(strstr(out, "RELAY_MODS_IN_GAME_TREE = \"\"") == NULL);
    /* The other globals are unaffected by the hint flag. */
    ASSERT_NOTNULL(strstr(out, "MOD_LOADER_DIR = \"Z:\\\\mod_loader\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"Z:\\\\mods\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_SKIP_SPLASH = \"\""));
    ASSERT_NOTNULL(strstr(out, "io.open(\"Z:\\\\mod_loader\\\\t.lua\", \"r\")"));
}

void test_build_chunk_mods_in_game_tree_disabled_emits_empty(void) {
    /* mods_in_game_tree 0 (the launcher-derived default: detection failed or
     * the mod path is elsewhere) bakes the empty-string global, exactly like
     * a disabled RELAY_SKIP_SPLASH. */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL,
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 0, 0, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_MODS_IN_GAME_TREE = \"\""));
    ASSERT_TRUE(strstr(out, "RELAY_MODS_IN_GAME_TREE = \"1\"") == NULL);
}

void test_build_chunk_globals_in_template_order(void) {
    /* All six baked globals appear in the template's fixed order, before the
     * io.open step: MOD_LOADER_DIR, RELAY_MOD_PATH, RELAY_MOD_MANAGER,
     * MOD_RELAY_VERSION, RELAY_SKIP_SPLASH, RELAY_MODS_IN_GAME_TREE. */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", "Z:\\tools\\mgr.exe",
                                   "Z:\\mod_loader\\t.lua", "0.2.0", 1, 1, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    const char *names[] = {
        "MOD_LOADER_DIR = ", "RELAY_MOD_PATH = ", "RELAY_MOD_MANAGER = ",
        "MOD_RELAY_VERSION = ", "RELAY_SKIP_SPLASH = ",
        "RELAY_MODS_IN_GAME_TREE = ", "local f, err = io.open(",
    };
    const char *prev = out;
    for (size_t k = 0; k < sizeof(names) / sizeof(names[0]); k++) {
        const char *at = strstr(prev, names[k]);
        if (at == NULL) {
            ASSERT_FAIL("expected \"%s\" in order after the previous global",
                        names[k]);
        }
        prev = at + 1;
    }
}

/* ---- trampoline_join_path ---- */

void test_join_basic_no_trailing_sep(void) {
    char out[64];
    int n = trampoline_join_path("Z:\\staging", "chunk.lua", out, sizeof(out));
    ASSERT_EQ(20, n);  /* "Z:\staging"(10) + "\"(1) + "chunk.lua"(9) */
    ASSERT_STREQ("Z:\\staging\\chunk.lua", out);  /* one backslash inserted */
}

void test_join_trailing_backslash_idempotent(void) {
    /* dir already ends in backslash -> no double separator. */
    char out[64];
    int n = trampoline_join_path("Z:\\staging\\", "chunk.lua", out, sizeof(out));
    ASSERT_EQ(20, n);  /* "Z:\staging\"(11) + "chunk.lua"(9), no extra sep */
    ASSERT_STREQ("Z:\\staging\\chunk.lua", out);
}

void test_join_trailing_fwdslash_accepted(void) {
    /* A trailing forward slash is tolerated as an already-present separator. */
    char out[64];
    int n = trampoline_join_path("Z:/staging/", "chunk.lua", out, sizeof(out));
    ASSERT_EQ(20, n);  /* "Z:/staging/"(11) + "chunk.lua"(9), no extra sep */
    ASSERT_STREQ("Z:/staging/chunk.lua", out);
}

void test_join_empty_dir_rejected(void) {
    char out[8];
    ASSERT_EQ(-1, trampoline_join_path("", "chunk.lua", out, sizeof(out)));
}

void test_join_empty_name_rejected(void) {
    char out[8];
    ASSERT_EQ(-1, trampoline_join_path("Z:\\staging", "", out, sizeof(out)));
}

void test_join_null_args(void) {
    char out[8];
    ASSERT_EQ(-1, trampoline_join_path(NULL, "chunk.lua", out, sizeof(out)));
    ASSERT_EQ(-1, trampoline_join_path("Z:\\staging", NULL, out, sizeof(out)));
    ASSERT_EQ(-1, trampoline_join_path("Z:\\staging", "chunk.lua", NULL, sizeof(out)));
    ASSERT_EQ(-1, trampoline_join_path("Z:\\staging", "chunk.lua", out, 0));
}

void test_join_overflow_returns_neg1(void) {
    /* need = "Z:\staging"(10) + "\"(1) + "chunk.lua"(9) = 20; +NUL = 21. cap 20 rejects. */
    char out[20];
    int n = trampoline_join_path("Z:\\staging", "chunk.lua", out, sizeof(out));
    ASSERT_EQ(-1, n);
}

void test_join_feeds_build_chunk(void) {
    /* End-to-end: join the loader root + entry filename, then build_chunk
     * with (loader root, mod root, joined entry). The loader root is passed
     * both as the global + as the join prefix of the entry path — intentional
     * (it's the same dir). Mirrors production: <dll-dir>\mod_loader joined
     * with init.lua. */
    char path[128];
    int jn = trampoline_join_path("Z:\\mod_loader", "init.lua", path, sizeof(path));
    ASSERT_TRUE(jn > 0);

    char chunk[1024];
    int cn = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL, path, "0.2.0", 0, 0, chunk, sizeof(chunk));
    ASSERT_TRUE(cn > 0);
    ASSERT_NOTNULL(strstr(chunk, "MOD_LOADER_DIR = \"Z:\\\\mod_loader\""));
    ASSERT_NOTNULL(strstr(chunk, "RELAY_MOD_PATH = \"Z:\\\\mods\""));
    ASSERT_NOTNULL(strstr(chunk, "io.open(\"Z:\\\\mod_loader\\\\init.lua\", \"r\")"));
}

int main(void) {
    test_register("escape_plain_path", test_escape_plain_path);
    test_register("escape_backslashes_doubled", test_escape_backslashes_doubled);
    test_register("escape_quote_doubled", test_escape_quote_doubled);
    test_register("escape_empty_path", test_escape_empty_path);
    test_register("escape_overflow_returns_neg1", test_escape_overflow_returns_neg1);
    test_register("escape_null_args", test_escape_null_args);
    test_register("has_control_clean_paths", test_has_control_clean_paths);
    test_register("has_control_detects_control_bytes",
                  test_has_control_detects_control_bytes);
    test_register("has_control_null_is_clean", test_has_control_null_is_clean);
    test_register("build_chunk_sets_both_path_globals_and_opens_entry",
                  test_build_chunk_sets_both_path_globals_and_opens_entry);
    test_register("build_chunk_plain_paths", test_build_chunk_plain_paths);
    test_register("build_chunk_null_mod_path_emits_empty_global",
                  test_build_chunk_null_mod_path_emits_empty_global);
    test_register("build_chunk_empty_mod_path_emits_empty_global",
                  test_build_chunk_empty_mod_path_emits_empty_global);
    test_register("build_chunk_mod_manager_set_emits_escaped_global",
                  test_build_chunk_mod_manager_set_emits_escaped_global);
    test_register("build_chunk_mod_manager_quote_is_escaped",
                  test_build_chunk_mod_manager_quote_is_escaped);
    test_register("build_chunk_null_mod_manager_emits_empty_global",
                  test_build_chunk_null_mod_manager_emits_empty_global);
    test_register("build_chunk_empty_mod_manager_emits_empty_global",
                  test_build_chunk_empty_mod_manager_emits_empty_global);
    test_register("build_chunk_mod_manager_set_with_null_mod_path",
                  test_build_chunk_mod_manager_set_with_null_mod_path);
    test_register("build_chunk_null_version_emits_nil_without_skipping_loader",
                  test_build_chunk_null_version_emits_nil_without_skipping_loader);
    test_register("build_chunk_empty_version_emits_nil",
                  test_build_chunk_empty_version_emits_nil);
    test_register("build_chunk_version_is_lua_escaped",
                  test_build_chunk_version_is_lua_escaped);
    test_register("build_chunk_overlong_version_emits_nil_without_skipping_loader",
                  test_build_chunk_overlong_version_emits_nil_without_skipping_loader);
    test_register("build_chunk_hands_off_exact_compiled_product_version",
                  test_build_chunk_hands_off_exact_compiled_product_version);
    test_register("build_chunk_empty_loader_dir_rejected",
                  test_build_chunk_empty_loader_dir_rejected);
    test_register("build_chunk_empty_entry_rejected",
                  test_build_chunk_empty_entry_rejected);
    test_register("build_chunk_null_args", test_build_chunk_null_args);
    test_register("build_chunk_overflow", test_build_chunk_overflow);
    test_register("build_chunk_round_trips_long_paths", test_build_chunk_round_trips_long_paths);
    test_register("build_chunk_skip_splash_enabled_emits_one",
                  test_build_chunk_skip_splash_enabled_emits_one);
    test_register("build_chunk_mods_in_game_tree_enabled_emits_one",
                  test_build_chunk_mods_in_game_tree_enabled_emits_one);
    test_register("build_chunk_mods_in_game_tree_disabled_emits_empty",
                  test_build_chunk_mods_in_game_tree_disabled_emits_empty);
    test_register("build_chunk_globals_in_template_order",
                  test_build_chunk_globals_in_template_order);
    test_register("join_basic_no_trailing_sep", test_join_basic_no_trailing_sep);
    test_register("join_trailing_backslash_idempotent", test_join_trailing_backslash_idempotent);
    test_register("join_trailing_fwdslash_accepted", test_join_trailing_fwdslash_accepted);
    test_register("join_empty_dir_rejected", test_join_empty_dir_rejected);
    test_register("join_empty_name_rejected", test_join_empty_name_rejected);
    test_register("join_null_args", test_join_null_args);
    test_register("join_overflow_returns_neg1", test_join_overflow_returns_neg1);
    test_register("join_feeds_build_chunk", test_join_feeds_build_chunk);
    return test_summary();
}
