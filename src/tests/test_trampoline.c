/*
 * test_trampoline.c — Unit tests for the production trampoline pure helpers.
 *
 * Covers trampoline_escape_path (the Windows-path -> Lua-string escape) and
 * trampoline_build_chunk (the full chunk assembly). These run via wine like the
 * other C tests; they compile trampoline.c directly (no Lua/Windows deps).
 */
#include "test_runner.h"
#include "../shell/src/trampoline.c"  /* compile the pure impl directly */
#include <stdio.h>
#include <string.h>

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

/* ---- trampoline_build_chunk ---- */

void test_build_chunk_sets_both_path_globals_and_opens_entry(void) {
    /* The chunk sets MOD_LOADER_DIR (escaped loader root) +
     * RELAY_MOD_PATH (escaped mod root), then opens the entry file (escaped
     * joined path). All three must appear. */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods",
                                   "Z:\\mod_loader\\t.lua", out, sizeof(out));
    ASSERT_TRUE(n > 0);

    /* Loader-root global (MOD_LOADER_DIR — internal, trampoline-set), escaped. */
    ASSERT_NOTNULL(strstr(out, "MOD_LOADER_DIR = \"Z:\\\\mod_loader\""));
    /* Mod-root global, escaped. */
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"Z:\\\\mods\""));
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
    int n = trampoline_build_chunk("/mod_loader", "/mods", "/mod_loader/x.lua",
                                   out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "MOD_LOADER_DIR = \"/mod_loader\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"/mods\""));
    ASSERT_NOTNULL(strstr(out, "io.open(\"/mod_loader/x.lua\", \"r\")"));
}

void test_build_chunk_null_mod_path_emits_empty_global(void) {
    /* mod_path NULL is the "no mods" case: the chunk emits RELAY_MOD_PATH = ""
     * and is still valid (entry loads from the loader root). */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", NULL,
                                   "Z:\\mod_loader\\t.lua", out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "MOD_LOADER_DIR = \"Z:\\\\mod_loader\""));
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"\""));
    ASSERT_NOTNULL(strstr(out, "io.open(\"Z:\\\\mod_loader\\\\t.lua\", \"r\")"));
}

void test_build_chunk_empty_mod_path_emits_empty_global(void) {
    /* An empty-string mod path is treated the same as NULL (no mods). */
    char out[1024];
    int n = trampoline_build_chunk("Z:\\mod_loader", "",
                                   "Z:\\mod_loader\\t.lua", out, sizeof(out));
    ASSERT_TRUE(n > 0);
    ASSERT_NOTNULL(strstr(out, "RELAY_MOD_PATH = \"\""));
}

void test_build_chunk_empty_loader_dir_rejected(void) {
    char out[64];
    ASSERT_EQ(-1, trampoline_build_chunk("", "Z:\\mods", "Z:\\t.lua", out, sizeof(out)));
}

void test_build_chunk_empty_entry_rejected(void) {
    char out[64];
    ASSERT_EQ(-1, trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", "", out, sizeof(out)));
}

void test_build_chunk_null_args(void) {
    char out[64];
    /* mod_loader_dir NULL -> rejected. */
    ASSERT_EQ(-1, trampoline_build_chunk(NULL, "Z:\\mods", "Z:\\t.lua", out, sizeof(out)));
    /* entry_path NULL -> rejected. */
    ASSERT_EQ(-1, trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", NULL, out, sizeof(out)));
    /* out NULL -> rejected. */
    ASSERT_EQ(-1, trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", "Z:\\t.lua", NULL, sizeof(out)));
    /* zero cap -> rejected. */
    ASSERT_EQ(-1, trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", "Z:\\t.lua", out, 0));
    /* (mod_path NULL is NOT an error — covered by the empty-global tests.) */
}

void test_build_chunk_overflow(void) {
    /* A tiny buffer cannot hold the chunk -> reject, no partial write relied on. */
    char out[8];
    int n = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods",
                                   "Z:\\mod_loader\\t.lua", out, sizeof(out));
    ASSERT_EQ(-1, n);
}

void test_build_chunk_round_trips_long_paths(void) {
    /* Realistically long Windows roots + entry still fit the default cap. */
    const char *loader = "Z:\\very\\deep\\path\\to\\the\\mod_loader\\root";
    const char *mods   = "Z:\\very\\deep\\path\\to\\the\\user\\mods\\dir";
    const char *entry  = "Z:\\very\\deep\\path\\to\\the\\mod_loader\\root\\file.lua";
    char out[1024];
    int n = trampoline_build_chunk(loader, mods, entry, out, sizeof(out));
    ASSERT_TRUE(n > 0);
    /* Every backslash in the original is doubled in the baked chunk. */
    ASSERT_NOTNULL(strstr(out, "Z:\\\\very\\\\deep\\\\path"));
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
    int cn = trampoline_build_chunk("Z:\\mod_loader", "Z:\\mods", path, chunk, sizeof(chunk));
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
    test_register("build_chunk_sets_both_path_globals_and_opens_entry",
                  test_build_chunk_sets_both_path_globals_and_opens_entry);
    test_register("build_chunk_plain_paths", test_build_chunk_plain_paths);
    test_register("build_chunk_null_mod_path_emits_empty_global",
                  test_build_chunk_null_mod_path_emits_empty_global);
    test_register("build_chunk_empty_mod_path_emits_empty_global",
                  test_build_chunk_empty_mod_path_emits_empty_global);
    test_register("build_chunk_empty_loader_dir_rejected",
                  test_build_chunk_empty_loader_dir_rejected);
    test_register("build_chunk_empty_entry_rejected",
                  test_build_chunk_empty_entry_rejected);
    test_register("build_chunk_null_args", test_build_chunk_null_args);
    test_register("build_chunk_overflow", test_build_chunk_overflow);
    test_register("build_chunk_round_trips_long_paths", test_build_chunk_round_trips_long_paths);
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
