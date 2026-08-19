/*
 * test_config.c — Unit tests for the launcher's config model.
 *
 * Validates the four guarantees:
 *   1. relay_parse_args: --flag <value> pairs populate the right fields;
 *      unknown flag / missing value / -h / --help return the right codes.
 *   2. relay_resolve_config: every setting follows flag > env > default,
 *      and RELAY_MOD_PATH / RELAY_MOD_MANAGER resolve to NULL when unset;
 *      an env RELAY_MOD_MANAGER too long for the buffer REFUSES (return 1,
 *      never a silent degrade to the built-in manager).
 *   3. relay_check_mod_manager: the alternate-manager pre-flight passes an
 *      unconfigured or existing regular file, and refuses a missing target
 *      or a directory.
 *   4. relay_derive_game_dir / relay_mods_in_game_tree: the mods-in-game-tree
 *      detection seams — pure two-segment game-dir derivation, and same-dir
 *      handle-identity detection (spelling-immune; 0 on any failure).
 *
 * resolve_config() writes env/default values into resolver-owned static
 * buffers that are reused on each call, so each test copies the value into a
 * local before re-resolving.
 */
#include "test_runner.h"
#include "../launcher/src/launcher.h"
#include <windows.h>
#include <stdio.h>
#include <string.h>

/* Env var names mirrored from launcher.c (kept private there, so redefine here
 * only to clean up state between resolve tests). */
#define ENV_GAME_BINARY  "RELAY_GAME_BINARY"
#define ENV_MOD_PATH     "RELAY_MOD_PATH"
#define ENV_MOD_MANAGER  "RELAY_MOD_MANAGER"
#define ENV_LOG_FILE     "RELAY_LOG_FILE"
#define ENV_LOG_LEVEL    "RELAY_LOG_LEVEL"
#define ENV_STEAM_APP_ID "RELAY_STEAM_APP_ID"
#define ENV_LOG_LUA      "RELAY_LOG_LUA"
#define ENV_LOG_APPEND   "RELAY_LOG_APPEND"
#define ENV_SKIP_SPLASH  "RELAY_SKIP_SPLASH"
#define ENV_MODS_IN_GAME_TREE "RELAY_MODS_IN_GAME_TREE"

static void clear_env(void) {
    SetEnvironmentVariableA(ENV_GAME_BINARY, NULL);
    SetEnvironmentVariableA(ENV_MOD_PATH, NULL);
    SetEnvironmentVariableA(ENV_MOD_MANAGER, NULL);
    SetEnvironmentVariableA(ENV_LOG_FILE, NULL);
    SetEnvironmentVariableA(ENV_LOG_LEVEL, NULL);
    SetEnvironmentVariableA(ENV_STEAM_APP_ID, NULL);
    SetEnvironmentVariableA(ENV_LOG_LUA, NULL);
    SetEnvironmentVariableA(ENV_LOG_APPEND, NULL);
    SetEnvironmentVariableA(ENV_SKIP_SPLASH, NULL);
    /* Set by main() (never by resolve), cleared here only for isolation:
     * these tests must not inherit a stray value from the environment. */
    SetEnvironmentVariableA(ENV_MODS_IN_GAME_TREE, NULL);
}

/* ---- parse_args ---- */

void test_parse_all_flags(void) {
    char *argv[] = {"prog",
        "--game-binary", "G", "--mod-path", "M", "--mod-manager", "MM",
        "--log-file", "L", "--log-level", "trace", "--steam-app-id", "42"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(13, argv, &a));
    ASSERT_STREQ("G", a.game_binary);
    ASSERT_STREQ("M", a.mod_path);
    ASSERT_STREQ("MM", a.mod_manager);
    ASSERT_STREQ("L", a.log_file);
    ASSERT_STREQ("trace", a.log_level);
    ASSERT_STREQ("42", a.steam_app_id);
}

void test_parse_none(void) {
    char *argv[] = {"prog"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(1, argv, &a));
    ASSERT_TRUE(a.game_binary == NULL);
    ASSERT_TRUE(a.mod_path == NULL);
    ASSERT_TRUE(a.mod_manager == NULL);
    ASSERT_TRUE(a.log_file == NULL);
    ASSERT_TRUE(a.log_level == NULL);
    ASSERT_TRUE(a.steam_app_id == NULL);
}

void test_parse_help_short(void) {
    char *argv[] = {"prog", "-h"};
    relay_parsed_args a;
    ASSERT_EQ(-2, relay_parse_args(2, argv, &a));
}

void test_parse_help_long(void) {
    char *argv[] = {"prog", "--help"};
    relay_parsed_args a;
    ASSERT_EQ(-2, relay_parse_args(2, argv, &a));
}

void test_parse_unknown_flag(void) {
    char *argv[] = {"prog", "--bogus", "x"};
    relay_parsed_args a;
    ASSERT_EQ(-1, relay_parse_args(3, argv, &a));
}

void test_parse_missing_value(void) {
    char *argv[] = {"prog", "--game-binary"};
    relay_parsed_args a;
    ASSERT_EQ(-1, relay_parse_args(2, argv, &a));
}

/* ---- game-argument tail: everything after the end-of-options `--` ---- */

void test_parse_dash_dash_forwards_tail_in_order(void) {
    char *argv[] = {"prog", "--", "a", "b", "c"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(5, argv, &a));
    ASSERT_EQ(3, a.game_argument_count);
    ASSERT_NOTNULL(a.game_arguments);
    ASSERT_STREQ("a", a.game_arguments[0]);
    ASSERT_STREQ("b", a.game_arguments[1]);
    ASSERT_STREQ("c", a.game_arguments[2]);
}

void test_parse_dash_dash_flag_looking_tokens_not_interpreted(void) {
    /* Tokens after -- that look like flags are raw game args, not Relay flags. */
    char *argv[] = {"prog", "--", "--x", "--y"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(4, argv, &a));
    ASSERT_EQ(2, a.game_argument_count);
    ASSERT_STREQ("--x", a.game_arguments[0]);
    ASSERT_STREQ("--y", a.game_arguments[1]);
}

void test_parse_dash_dash_relay_mod_path_not_set_after_separator(void) {
    /* The key correctness case: --mod-path after -- is a game arg, NOT Relay's
     * mod_path. Relay's own mod_path must stay NULL. */
    char *argv[] = {"prog", "--", "--mod-path", "foo"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(4, argv, &a));
    ASSERT_TRUE(a.mod_path == NULL);  /* Relay's --mod-path was NOT set */
    ASSERT_EQ(2, a.game_argument_count);
    ASSERT_STREQ("--mod-path", a.game_arguments[0]);
    ASSERT_STREQ("foo", a.game_arguments[1]);
}

void test_parse_dash_dash_relay_mod_manager_not_set_after_separator(void) {
    /* Same rule for --mod-manager: after -- it is a game arg, NOT Relay's
     * mod_manager. Relay's own mod_manager must stay NULL. */
    char *argv[] = {"prog", "--", "--mod-manager", "mgr.exe"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(4, argv, &a));
    ASSERT_TRUE(a.mod_manager == NULL);  /* Relay's --mod-manager was NOT set */
    ASSERT_EQ(2, a.game_argument_count);
    ASSERT_STREQ("--mod-manager", a.game_arguments[0]);
    ASSERT_STREQ("mgr.exe", a.game_arguments[1]);
}

void test_parse_dash_dash_version_not_set_after_separator(void) {
    /* --version after -- is a game arg, NOT Relay's --version. */
    char *argv[] = {"prog", "--", "--version"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_FALSE(a.show_version);  /* Relay's --version was NOT triggered */
    ASSERT_EQ(1, a.game_argument_count);
    ASSERT_STREQ("--version", a.game_arguments[0]);
}

void test_parse_dash_dash_help_not_triggered_after_separator(void) {
    /* --help after -- is a game arg, NOT Relay's help: parse must return 0
     * (NOT -2), forwarded as the tail. */
    char *argv[] = {"prog", "--", "--help"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_EQ(1, a.game_argument_count);
    ASSERT_STREQ("--help", a.game_arguments[0]);
    ASSERT_FALSE(a.show_version);
}

void test_parse_dash_dash_short_help_not_triggered_after_separator(void) {
    /* Same for -h after -- (a raw game arg, not Relay's -h). */
    char *argv[] = {"prog", "--", "-h"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_EQ(1, a.game_argument_count);
    ASSERT_STREQ("-h", a.game_arguments[0]);
}

void test_parse_dash_dash_preserves_duplicates(void) {
    char *argv[] = {"prog", "--", "a", "a", "b"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(5, argv, &a));
    ASSERT_EQ(3, a.game_argument_count);
    ASSERT_STREQ("a", a.game_arguments[0]);
    ASSERT_STREQ("a", a.game_arguments[1]);
    ASSERT_STREQ("b", a.game_arguments[2]);
}

void test_parse_dash_dash_with_nothing_after(void) {
    char *argv[] = {"prog", "--game-binary", "G", "--"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(4, argv, &a));
    ASSERT_EQ(0, a.game_argument_count);
    ASSERT_TRUE(a.game_arguments == NULL);  /* zero args => NULL pointer */
}

void test_parse_no_dash_dash_means_no_game_args(void) {
    char *argv[] = {"prog", "--game-binary", "G", "--mod-path", "M"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(5, argv, &a));
    ASSERT_EQ(0, a.game_argument_count);
    ASSERT_TRUE(a.game_arguments == NULL);
    /* And the regular flags still parsed. */
    ASSERT_STREQ("G", a.game_binary);
    ASSERT_STREQ("M", a.mod_path);
}

void test_parse_dash_dash_after_regular_flags(void) {
    /* Single-value flags before -- resolve normally; the tail follows. */
    char *argv[] = {"prog", "--game-binary", "G", "--log-level", "debug", "--",
                    "--ini", "settings"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(8, argv, &a));
    ASSERT_STREQ("G", a.game_binary);
    ASSERT_STREQ("debug", a.log_level);
    ASSERT_EQ(2, a.game_argument_count);
    ASSERT_STREQ("--ini", a.game_arguments[0]);
    ASSERT_STREQ("settings", a.game_arguments[1]);
}

void test_parse_single_value_missing_value_before_dash_dash(void) {
    /* A missing value for a single-value flag (before --) still returns -1. */
    char *argv[] = {"prog", "--game-binary"};
    relay_parsed_args a;
    ASSERT_EQ(-1, relay_parse_args(2, argv, &a));
}

void test_parse_version_before_dash_dash_sets_flag(void) {
    /* --version BEFORE -- sets show_version (main early-exits on it before
     * caring about the tail; here we just confirm parse sets the flag). */
    char *argv[] = {"prog", "--version", "--", "x"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(4, argv, &a));
    ASSERT_TRUE(a.show_version);
    ASSERT_EQ(1, a.game_argument_count);
    ASSERT_STREQ("x", a.game_arguments[0]);
}

void test_parse_dash_dash_operator_scenario(void) {
    /* The operator's scenario: --lua-heap-mb-size and 2048 forward as TWO
     * separate tokens. */
    char *argv[] = {"prog", "--game-binary", "X", "--", "--lua-heap-mb-size",
                    "2048"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(6, argv, &a));
    ASSERT_EQ(2, a.game_argument_count);
    ASSERT_STREQ("--lua-heap-mb-size", a.game_arguments[0]);
    ASSERT_STREQ("2048", a.game_arguments[1]);
}

/* ---- --version flag ---- */

void test_parse_version_sets_flag(void) {
    char *argv[] = {"prog", "--version"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(2, argv, &a));
    ASSERT_TRUE(a.show_version);
}

void test_parse_version_valueless(void) {
    /* --version must NOT consume the following token: --game-binary still
     * parses normally. */
    char *argv[] = {"prog", "--version", "--game-binary", "G"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(4, argv, &a));
    ASSERT_TRUE(a.show_version);
    ASSERT_STREQ("G", a.game_binary);
}

void test_parse_version_defaults_false(void) {
    char *argv[] = {"prog", "--game-binary", "G"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_FALSE(a.show_version);
}

/* ---- resolve_config: flag > env > default ---- */

void test_resolve_flag_wins(void) {
    clear_env();
    SetEnvironmentVariableA(ENV_LOG_LEVEL, "warn");
    SetEnvironmentVariableA(ENV_STEAM_APP_ID, "111");

    relay_parsed_args a = {0};
    a.log_level = "FLAG_LEVEL";
    a.steam_app_id = "FLAG_ID";
    a.game_binary = "FLAG_GAME";

    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_STREQ("FLAG_GAME", cfg.game_binary);
    ASSERT_STREQ("FLAG_LEVEL", cfg.log_level);
    ASSERT_STREQ("FLAG_ID", cfg.steam_app_id);

    clear_env();
}

void test_resolve_env_when_no_flag(void) {
    clear_env();
    SetEnvironmentVariableA(ENV_GAME_BINARY, "ENV_GAME");
    SetEnvironmentVariableA(ENV_MOD_PATH, "ENV_MOD");
    SetEnvironmentVariableA(ENV_MOD_MANAGER, "ENV_MGR");
    SetEnvironmentVariableA(ENV_LOG_FILE, "ENV_LOG");
    SetEnvironmentVariableA(ENV_LOG_LEVEL, "debug");
    SetEnvironmentVariableA(ENV_STEAM_APP_ID, "222");

    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_STREQ("ENV_GAME", cfg.game_binary);
    ASSERT_STREQ("ENV_MOD", cfg.mod_path);
    ASSERT_STREQ("ENV_MGR", cfg.mod_manager);
    ASSERT_STREQ("ENV_LOG", cfg.log_file);
    ASSERT_STREQ("debug", cfg.log_level);
    ASSERT_STREQ("222", cfg.steam_app_id);

    clear_env();
}

void test_resolve_defaults_when_nothing_set(void) {
    clear_env();
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    /* game_binary has no default: must be NULL (main() rejects this). */
    ASSERT_TRUE(cfg.game_binary == NULL);
    /* mod_path is optional: NULL when unset. */
    ASSERT_TRUE(cfg.mod_path == NULL);
    /* mod_manager is optional: NULL when unset. */
    ASSERT_TRUE(cfg.mod_manager == NULL);
    /* log_level + steam_app_id have literal defaults. */
    ASSERT_STREQ("info", cfg.log_level);
    ASSERT_STREQ("1361210", cfg.steam_app_id);
    /* log_file defaults to <launcher-dir>\<name>: can't know the dir here,
     * but it must end with the right leaf and be non-empty. (The injected DLL
     * is hardcoded in main() — not a resolved config field — so it has no
     * default to check here.) */
    ASSERT_TRUE(cfg.log_file != NULL);
    ASSERT_TRUE(strlen(cfg.log_file) > 0);
    ASSERT_TRUE(strstr(cfg.log_file, "relay.log") != NULL);
    clear_env();
}

void test_resolve_mod_path_unset_is_null_with_flag_present(void) {
    /* mod_path stays optional even when other settings come from flags. */
    clear_env();
    relay_parsed_args a = {0};
    a.game_binary = "G";
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_TRUE(cfg.mod_path == NULL);
    clear_env();
}

void test_resolve_mod_manager_flag_wins_over_env(void) {
    /* mod_manager follows the same precedence as mod_path: flag > env. */
    clear_env();
    SetEnvironmentVariableA(ENV_MOD_MANAGER, "ENV_MGR");
    relay_parsed_args a = {0};
    a.mod_manager = "FLAG_MGR";
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_STREQ("FLAG_MGR", cfg.mod_manager);
    clear_env();
}

void test_resolve_mod_manager_env_used_when_no_flag(void) {
    clear_env();
    SetEnvironmentVariableA(ENV_MOD_MANAGER, "ENV_MGR");
    relay_parsed_args a = {0};
    relay_config cfg;
    ASSERT_EQ(0, relay_resolve_config(&a, &cfg));
    ASSERT_STREQ("ENV_MGR", cfg.mod_manager);
    clear_env();
}

void test_resolve_mod_manager_unset_is_null(void) {
    /* No flag, no env => NULL (no alternate manager; the trampoline emits an
     * empty RELAY_MOD_MANAGER). */
    clear_env();
    relay_parsed_args a = {0};
    a.game_binary = "G";
    relay_config cfg;
    ASSERT_EQ(0, relay_resolve_config(&a, &cfg));
    ASSERT_TRUE(cfg.mod_manager == NULL);
    clear_env();
}

void test_resolve_mod_manager_env_empty_is_null(void) {
    /* An empty env value is "not provided" (same as unset — the trampoline
     * emits an empty RELAY_MOD_MANAGER; no alternate manager). */
    clear_env();
    SetEnvironmentVariableA(ENV_MOD_MANAGER, "");
    relay_parsed_args a = {0};
    relay_config cfg;
    ASSERT_EQ(0, relay_resolve_config(&a, &cfg));
    ASSERT_TRUE(cfg.mod_manager == NULL);
    clear_env();
}

void test_resolve_mod_manager_env_oversized_refuses(void) {
    /* A PRESENT but oversized env value must REFUSE (return 1), not degrade
     * to the built-in manager: the operator configured an alternate, and a
     * silent substitution would launch a managerless game (the
     * never-silently-substitute policy). Contrast mod_path, where
     * degrade-to-unset is correct for an optional value. */
    clear_env();
    char big[1200];
    memset(big, 'x', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    SetEnvironmentVariableA(ENV_MOD_MANAGER, big);
    relay_parsed_args a = {0};
    relay_config cfg;
    ASSERT_EQ(1, relay_resolve_config(&a, &cfg));
    ASSERT_TRUE(cfg.mod_manager == NULL);  /* never silently substituted */
    clear_env();
}

void test_resolve_mod_manager_env_oversized_ignored_when_flag_present(void) {
    /* Flag > env: a valid --mod-manager flag wins even when the env value is
     * oversized (the env var is simply never read). */
    clear_env();
    char big[1200];
    memset(big, 'x', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    SetEnvironmentVariableA(ENV_MOD_MANAGER, big);
    relay_parsed_args a = {0};
    a.mod_manager = "FLAG_MGR";
    relay_config cfg;
    ASSERT_EQ(0, relay_resolve_config(&a, &cfg));
    ASSERT_STREQ("FLAG_MGR", cfg.mod_manager);
    clear_env();
}

/* ---- alternate mod manager pre-flight (relay_check_mod_manager) ---- */

/* Resolve this test executable's own path (an existing regular file) and its
 * directory, so the pre-flight tests need no fixtures. */
static int self_path(char *out, size_t outsz) {
    DWORD n = GetModuleFileNameA(NULL, out, (DWORD)outsz);
    if (n == 0 || n >= outsz) return -1;
    return 0;
}

void test_check_mod_manager_not_configured_passes(void) {
    /* NULL (not configured) is an immediate pass: absent config behaves
     * exactly as before the flag existed. */
    ASSERT_EQ(0, relay_check_mod_manager(NULL, "--mod-manager"));
}

void test_check_mod_manager_existing_file_passes(void) {
    /* This test exe is an existing regular file. */
    char self[MAX_PATH];
    if (self_path(self, sizeof(self)) != 0) {
        ASSERT_FAIL("could not resolve the test exe path");
    }
    ASSERT_EQ(0, relay_check_mod_manager(self, "env RELAY_MOD_MANAGER"));
}

void test_check_mod_manager_missing_fails(void) {
    char self[MAX_PATH];
    if (self_path(self, sizeof(self)) != 0) {
        ASSERT_FAIL("could not resolve the test exe path");
    }
    char missing[MAX_PATH];
    snprintf(missing, sizeof(missing), "%s.no_such_manager", self);
    ASSERT_EQ(1, relay_check_mod_manager(missing, "--mod-manager"));
}

void test_check_mod_manager_directory_fails(void) {
    /* The test exe's own directory exists but is a directory, not a regular
     * file — the manager slot points at a file, so this must refuse. */
    char self[MAX_PATH];
    if (self_path(self, sizeof(self)) != 0) {
        ASSERT_FAIL("could not resolve the test exe path");
    }
    char *slash = strrchr(self, '\\');
    ASSERT_NOTNULL(slash);
    *slash = '\0';  /* self is now the exe's directory */
    ASSERT_EQ(1, relay_check_mod_manager(self, "env RELAY_MOD_MANAGER"));
}

/* ---- mods-in-game-tree detection (relay_derive_game_dir + relay_mods_in_game_tree) ---- */

/* ---- relay_derive_game_dir (pure string math) ---- */

void test_derive_game_dir_backslash_path(void) {
    char out[128];
    ASSERT_EQ(0, relay_derive_game_dir(
        "C:\\Games\\Darktide\\binaries\\Darktide.exe", out, sizeof(out)));
    ASSERT_STREQ("C:\\Games\\Darktide", out);
}

void test_derive_game_dir_forward_slashes_preserved(void) {
    /* Forward slashes are separators too, and the caller's separator bytes
     * are preserved in the output. */
    char out[128];
    ASSERT_EQ(0, relay_derive_game_dir(
        "C:/Games/Darktide/binaries/Darktide.exe", out, sizeof(out)));
    ASSERT_STREQ("C:/Games/Darktide", out);
}

void test_derive_game_dir_mixed_separators(void) {
    char out[128];
    ASSERT_EQ(0, relay_derive_game_dir(
        "C:/Games/Darktide\\binaries/Darktide.exe", out, sizeof(out)));
    ASSERT_STREQ("C:/Games/Darktide", out);
}

void test_derive_game_dir_trailing_separator_tolerated(void) {
    char out[128];
    ASSERT_EQ(0, relay_derive_game_dir(
        "C:\\Games\\Darktide\\binaries\\Darktide.exe\\", out, sizeof(out)));
    ASSERT_STREQ("C:\\Games\\Darktide", out);
    ASSERT_EQ(0, relay_derive_game_dir(
        "C:\\Games\\Darktide\\binaries\\Darktide.exe//", out, sizeof(out)));
    ASSERT_STREQ("C:\\Games\\Darktide", out);
}

void test_derive_game_dir_bare_filename_fails(void) {
    char out[128];
    ASSERT_EQ(-1, relay_derive_game_dir("Darktide.exe", out, sizeof(out)));
}

void test_derive_game_dir_one_level_fails(void) {
    /* Only one separator: no segment above "binaries" to yield a game dir. */
    char out[128];
    ASSERT_EQ(-1, relay_derive_game_dir("binaries\\Darktide.exe", out, sizeof(out)));
    ASSERT_EQ(-1, relay_derive_game_dir("/binaries/Darktide.exe", out, sizeof(out)));
}

void test_derive_game_dir_root_relative_empty_prefix_fails(void) {
    /* "\binaries\x.exe" has two separators but an empty prefix — an empty
     * game dir is not a usable derivation result. */
    char out[128];
    ASSERT_EQ(-1, relay_derive_game_dir("\\binaries\\Darktide.exe", out, sizeof(out)));
}

void test_derive_game_dir_null_and_empty_args(void) {
    char out[8];
    ASSERT_EQ(-1, relay_derive_game_dir(NULL, out, sizeof(out)));
    ASSERT_EQ(-1, relay_derive_game_dir("C:\\g\\binaries\\Darktide.exe", NULL, sizeof(out)));
    ASSERT_EQ(-1, relay_derive_game_dir("C:\\g\\binaries\\Darktide.exe", out, 0));
    ASSERT_EQ(-1, relay_derive_game_dir("", out, sizeof(out)));
}

void test_derive_game_dir_overflow_fails(void) {
    /* The derived dir "C:\Games" is 8 chars: cap 8 cannot hold it + NUL,
     * cap 9 can. */
    char out[16];
    ASSERT_EQ(-1, relay_derive_game_dir(
        "C:\\Games\\binaries\\Darktide.exe", out, 8));
    ASSERT_EQ(0, relay_derive_game_dir(
        "C:\\Games\\binaries\\Darktide.exe", out, 9));
    ASSERT_STREQ("C:\\Games", out);
}

/* ---- relay_mods_in_game_tree (real dirs under the temp dir; wine) ---- */

/* Build a scratch game tree under the temp dir:
 *   <tmp>\relay_igt_<pid>\game\binaries\
 * The exe path itself never needs to exist — derivation is pure string math
 * and detection only opens the DIRECTORIES. The pid-scoped root tolerates
 * leftovers from an aborted run. Returns 0 on success. */
static int make_game_tree(char *root, size_t rsz,
                          char *game_dir, size_t gdsz,
                          char *game_binary, size_t gbsz) {
    char tmp[MAX_PATH];
    DWORD tn = GetTempPathA(sizeof(tmp), tmp);
    if (tn == 0 || tn >= sizeof(tmp)) return -1;
    snprintf(root, rsz, "%srelay_igt_%lu", tmp, GetCurrentProcessId());
    snprintf(game_dir, gdsz, "%s\\game", root);
    snprintf(game_binary, gbsz, "%s\\binaries\\Darktide.exe", game_dir);
    char binaries[MAX_PATH];
    snprintf(binaries, sizeof(binaries), "%s\\binaries", game_dir);
    if (!CreateDirectoryA(root, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return -1;
    if (!CreateDirectoryA(game_dir, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return -1;
    if (!CreateDirectoryA(binaries, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return -1;
    return 0;
}

/* Best-effort cleanup of everything the tests may have created under root. */
static void remove_game_tree(const char *root) {
    char sub[MAX_PATH];
    snprintf(sub, sizeof(sub), "%s\\game\\binaries", root); RemoveDirectoryA(sub);
    snprintf(sub, sizeof(sub), "%s\\game", root);          RemoveDirectoryA(sub);
    snprintf(sub, sizeof(sub), "%s\\other", root);         RemoveDirectoryA(sub);
    snprintf(sub, sizeof(sub), "%s\\link", root);          RemoveDirectoryA(sub);
    snprintf(sub, sizeof(sub), "%s\\file.dat", root);      DeleteFileA(sub);
    RemoveDirectoryA(root);
}

void test_in_game_tree_same_dir_variant_spellings_match(void) {
    /* The whole point of handle identity: different spellings of the SAME
     * directory (trailing separator, forward slashes, different case) all
     * compare equal — no path-text comparison anywhere. */
    char root[MAX_PATH], gd[MAX_PATH], gb[MAX_PATH], variant[MAX_PATH];
    if (make_game_tree(root, sizeof(root), gd, sizeof(gd), gb, sizeof(gb)) != 0) {
        ASSERT_FAIL("could not create the scratch game tree");
    }

    ASSERT_EQ(1, relay_mods_in_game_tree(gb, gd));

    snprintf(variant, sizeof(variant), "%s\\", gd);
    ASSERT_EQ(1, relay_mods_in_game_tree(gb, variant));

    snprintf(variant, sizeof(variant), "%s", gd);
    for (char *p = variant; *p; p++) {
        if (*p == '\\') *p = '/';
    }
    ASSERT_EQ(1, relay_mods_in_game_tree(gb, variant));

    /* Case differences (ASCII upper): NTFS and wine's prefix drives are
     * case-insensitive, and the handle identity is unchanged regardless. */
    snprintf(variant, sizeof(variant), "%s", gd);
    for (char *p = variant; *p; p++) {
        if (*p >= 'a' && *p <= 'z') *p = (char)(*p - 32);
    }
    ASSERT_EQ(1, relay_mods_in_game_tree(gb, variant));

    remove_game_tree(root);
}

void test_in_game_tree_different_dir_does_not_match(void) {
    char root[MAX_PATH], gd[MAX_PATH], gb[MAX_PATH], other[MAX_PATH];
    if (make_game_tree(root, sizeof(root), gd, sizeof(gd), gb, sizeof(gb)) != 0) {
        ASSERT_FAIL("could not create the scratch game tree");
    }
    snprintf(other, sizeof(other), "%s\\other", root);
    if (!CreateDirectoryA(other, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) {
        remove_game_tree(root);
        ASSERT_FAIL("could not create the sibling dir");
    }
    ASSERT_EQ(0, relay_mods_in_game_tree(gb, other));
    remove_game_tree(root);
}

void test_in_game_tree_nonexistent_mod_path_is_zero(void) {
    char root[MAX_PATH], gd[MAX_PATH], gb[MAX_PATH], missing[MAX_PATH];
    if (make_game_tree(root, sizeof(root), gd, sizeof(gd), gb, sizeof(gb)) != 0) {
        ASSERT_FAIL("could not create the scratch game tree");
    }
    snprintf(missing, sizeof(missing), "%s\\no_such_dir", root);
    ASSERT_EQ(0, relay_mods_in_game_tree(gb, missing));
    remove_game_tree(root);
}

void test_in_game_tree_null_mod_path_is_zero(void) {
    char root[MAX_PATH], gd[MAX_PATH], gb[MAX_PATH];
    if (make_game_tree(root, sizeof(root), gd, sizeof(gd), gb, sizeof(gb)) != 0) {
        ASSERT_FAIL("could not create the scratch game tree");
    }
    ASSERT_EQ(0, relay_mods_in_game_tree(gb, NULL));
    remove_game_tree(root);
}

void test_in_game_tree_underivable_game_dir_is_zero(void) {
    /* A bare exe name cannot yield a game dir: detection degrades to 0, the
     * default (retargeting stays on). */
    char root[MAX_PATH], gd[MAX_PATH], gb[MAX_PATH];
    if (make_game_tree(root, sizeof(root), gd, sizeof(gd), gb, sizeof(gb)) != 0) {
        ASSERT_FAIL("could not create the scratch game tree");
    }
    ASSERT_EQ(0, relay_mods_in_game_tree("Darktide.exe", gd));
    remove_game_tree(root);
}

void test_in_game_tree_mod_path_is_a_file_is_zero(void) {
    /* A mod path that exists but is a regular file is not the game dir:
     * the file identity never matches the game dir's. */
    char root[MAX_PATH], gd[MAX_PATH], gb[MAX_PATH], file[MAX_PATH];
    if (make_game_tree(root, sizeof(root), gd, sizeof(gd), gb, sizeof(gb)) != 0) {
        ASSERT_FAIL("could not create the scratch game tree");
    }
    snprintf(file, sizeof(file), "%s\\file.dat", root);
    HANDLE h = CreateFileA(file, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        remove_game_tree(root);
        ASSERT_FAIL("could not create the scratch file");
    }
    CloseHandle(h);
    ASSERT_EQ(0, relay_mods_in_game_tree(gb, file));
    remove_game_tree(root);
}

void test_in_game_tree_symlink_to_game_dir_matches(void) {
    /* Same dir via a directory symlink: opening the link (no
     * FILE_FLAG_OPEN_REPARSE_POINT) resolves to the target, so the handle
     * identity matches. Symlink creation needs privileges/developer mode on
     * native Windows and can be unavailable under wine — when it fails the
     * test self-skips rather than fail intermittently. */
    char root[MAX_PATH], gd[MAX_PATH], gb[MAX_PATH], link[MAX_PATH];
    if (make_game_tree(root, sizeof(root), gd, sizeof(gd), gb, sizeof(gb)) != 0) {
        ASSERT_FAIL("could not create the scratch game tree");
    }
    snprintf(link, sizeof(link), "%s\\link", root);
    if (CreateSymbolicLinkA(link, gd,
                            SYMBOLIC_LINK_FLAG_DIRECTORY |
                            SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
        ASSERT_EQ(1, relay_mods_in_game_tree(gb, link));
    } else {
        printf("  (skip: CreateSymbolicLinkA unavailable in this environment)\n");
    }
    remove_game_tree(root);
}

void test_resolve_game_arguments_threaded_unchanged(void) {
    /* Game arguments (the -- tail) have NO env/default layer: resolve must copy
     * the pointer and count through verbatim (same borrowed slice, same order). */
    clear_env();
    char *argv[] = {"prog", "--game-binary", "G", "--", "alpha", "beta beta"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(6, argv, &a));
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_EQ(a.game_argument_count, cfg.game_argument_count);
    ASSERT_TRUE(cfg.game_arguments == a.game_arguments);  /* same slice */
    ASSERT_STREQ("alpha", cfg.game_arguments[0]);
    ASSERT_STREQ("beta beta", cfg.game_arguments[1]);
    clear_env();
}

void test_resolve_game_arguments_none_is_null(void) {
    /* No `--` => NULL + 0 (no env layer to fall back on). */
    clear_env();
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_EQ(0, cfg.game_argument_count);
    ASSERT_TRUE(cfg.game_arguments == NULL);
    clear_env();
}

/* ---- --log-lua flag (value-less, default-off, exact env) ---- */

void test_parse_log_lua_valueless(void) {
    /* --log-lua must NOT consume the following token: --game-binary still
     * parses normally. */
    char *argv[] = {"prog", "--log-lua", "--game-binary", "G"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(4, argv, &a));
    ASSERT_TRUE(a.log_lua_enabled);
    ASSERT_STREQ("G", a.game_binary);
}

void test_parse_log_lua_defaults_false(void) {
    char *argv[] = {"prog", "--game-binary", "G"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_FALSE(a.log_lua_enabled);
}

void test_parse_log_lua_after_dash_dash_is_game_arg(void) {
    /* --log-lua after -- is a raw game arg, NOT Relay's flag. Relay's own
     * log_lua_enabled must stay false, and the token forwards in the tail. */
    char *argv[] = {"prog", "--", "--log-lua"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_FALSE(a.log_lua_enabled);
    ASSERT_EQ(1, a.game_argument_count);
    ASSERT_STREQ("--log-lua", a.game_arguments[0]);
}

void test_resolve_log_lua_default_off(void) {
    /* No flag, no env => disabled. */
    clear_env();
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_FALSE(cfg.log_lua_enabled);
    clear_env();
}

void test_resolve_log_lua_env_exact_one_enables(void) {
    /* Only the exact value "1" enables. */
    clear_env();
    SetEnvironmentVariableA(ENV_LOG_LUA, "1");
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_TRUE(cfg.log_lua_enabled);
    clear_env();
}

void test_resolve_log_lua_env_other_values_disabled(void) {
    /* Every non-"1" value disables (unset is covered by default_off). */
    clear_env();
    const char *bad[] = {"0", "true", "TRUE", "2", "yes", " 1", "1 ",
                         "on", "  ", "True", "11", "1.0"};
    for (int k = 0; k < (int)(sizeof(bad) / sizeof(bad[0])); k++) {
        SetEnvironmentVariableA(ENV_LOG_LUA, bad[k]);
        relay_parsed_args a = {0};
        relay_config cfg;
        relay_resolve_config(&a, &cfg);
        if (cfg.log_lua_enabled) {
            ASSERT_FAIL("RELAY_LOG_LUA=\"%s\" should disable, but enabled",
                        bad[k]);
        }
    }
    clear_env();
}

void test_resolve_log_lua_env_empty_disables(void) {
    /* An explicitly-empty value must disable (not enable). */
    clear_env();
    SetEnvironmentVariableA(ENV_LOG_LUA, "");
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_FALSE(cfg.log_lua_enabled);
    clear_env();
}

void test_resolve_log_lua_env_oversized_disables(void) {
    /* An oversized value (would truncate the probe buffer) disables. */
    clear_env();
    char big[32];
    memset(big, '1', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    SetEnvironmentVariableA(ENV_LOG_LUA, big);
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_FALSE(cfg.log_lua_enabled);
    clear_env();
}

void test_resolve_log_lua_flag_wins_and_enables_with_invalid_env(void) {
    /* Explicit --log-lua enables even when the env is set to an invalid
     * value (flag > env). */
    clear_env();
    SetEnvironmentVariableA(ENV_LOG_LUA, "true");
    relay_parsed_args a = {0};
    a.log_lua_enabled = 1;
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_TRUE(cfg.log_lua_enabled);
    clear_env();
}

/* ---- --log-append flag (value-less, default-off, exact env) ---- */

void test_parse_log_append_valueless(void) {
    /* --log-append must NOT consume the following token: --game-binary still
     * parses normally. */
    char *argv[] = {"prog", "--log-append", "--game-binary", "G"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(4, argv, &a));
    ASSERT_TRUE(a.log_append_enabled);
    ASSERT_STREQ("G", a.game_binary);
}

void test_parse_log_append_defaults_false(void) {
    char *argv[] = {"prog", "--game-binary", "G"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_FALSE(a.log_append_enabled);
}

void test_parse_log_append_after_dash_dash_is_game_arg(void) {
    /* --log-append after -- is a raw game arg, NOT Relay's flag. Relay's own
     * log_append_enabled must stay false, and the token forwards in the tail. */
    char *argv[] = {"prog", "--", "--log-append"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_FALSE(a.log_append_enabled);
    ASSERT_EQ(1, a.game_argument_count);
    ASSERT_STREQ("--log-append", a.game_arguments[0]);
}

void test_resolve_log_append_default_off(void) {
    /* No flag, no env => disabled. */
    clear_env();
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_FALSE(cfg.log_append_enabled);
    clear_env();
}

void test_resolve_log_append_env_exact_one_enables(void) {
    /* Only the exact value "1" enables. */
    clear_env();
    SetEnvironmentVariableA(ENV_LOG_APPEND, "1");
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_TRUE(cfg.log_append_enabled);
    clear_env();
}

void test_resolve_log_append_env_other_values_disabled(void) {
    /* Every non-"1" value disables (unset is covered by default_off). */
    clear_env();
    const char *bad[] = {"0", "true", "TRUE", "2", "yes", " 1", "1 ",
                         "on", "  ", "True", "11", "1.0"};
    for (int k = 0; k < (int)(sizeof(bad) / sizeof(bad[0])); k++) {
        SetEnvironmentVariableA(ENV_LOG_APPEND, bad[k]);
        relay_parsed_args a = {0};
        relay_config cfg;
        relay_resolve_config(&a, &cfg);
        if (cfg.log_append_enabled) {
            ASSERT_FAIL("RELAY_LOG_APPEND=\"%s\" should disable, but enabled",
                        bad[k]);
        }
    }
    clear_env();
}

void test_resolve_log_append_env_empty_disables(void) {
    /* An explicitly-empty value must disable (not enable). */
    clear_env();
    SetEnvironmentVariableA(ENV_LOG_APPEND, "");
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_FALSE(cfg.log_append_enabled);
    clear_env();
}

void test_resolve_log_append_env_oversized_disables(void) {
    /* An oversized value (would truncate the probe buffer) disables. */
    clear_env();
    char big[32];
    memset(big, '1', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    SetEnvironmentVariableA(ENV_LOG_APPEND, big);
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_FALSE(cfg.log_append_enabled);
    clear_env();
}

void test_resolve_log_append_flag_wins_and_enables_with_invalid_env(void) {
    /* Explicit --log-append enables even when the env is set to an invalid
     * value (flag > env). */
    clear_env();
    SetEnvironmentVariableA(ENV_LOG_APPEND, "true");
    relay_parsed_args a = {0};
    a.log_append_enabled = 1;
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_TRUE(cfg.log_append_enabled);
    clear_env();
}

/* ---- --skip-splash flag (value-less, default-off, exact env) ---- */

void test_parse_skip_splash_valueless(void) {
    /* --skip-splash must NOT consume the following token: --game-binary still
     * parses normally. */
    char *argv[] = {"prog", "--skip-splash", "--game-binary", "G"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(4, argv, &a));
    ASSERT_TRUE(a.skip_splash_enabled);
    ASSERT_STREQ("G", a.game_binary);
}

void test_parse_skip_splash_defaults_false(void) {
    char *argv[] = {"prog", "--game-binary", "G"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_FALSE(a.skip_splash_enabled);
}

void test_parse_skip_splash_after_dash_dash_is_game_arg(void) {
    /* --skip-splash after -- is a raw game arg, NOT Relay's flag. Relay's own
     * skip_splash_enabled must stay false, and the token forwards in the tail. */
    char *argv[] = {"prog", "--", "--skip-splash"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(3, argv, &a));
    ASSERT_FALSE(a.skip_splash_enabled);
    ASSERT_EQ(1, a.game_argument_count);
    ASSERT_STREQ("--skip-splash", a.game_arguments[0]);
}

void test_resolve_skip_splash_default_off(void) {
    /* No flag, no env => disabled. */
    clear_env();
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_FALSE(cfg.skip_splash_enabled);
    clear_env();
}

void test_resolve_skip_splash_env_exact_one_enables(void) {
    /* Only the exact value "1" enables. */
    clear_env();
    SetEnvironmentVariableA(ENV_SKIP_SPLASH, "1");
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_TRUE(cfg.skip_splash_enabled);
    clear_env();
}

void test_resolve_skip_splash_env_other_values_disabled(void) {
    /* Every non-"1" value disables (unset is covered by default_off). */
    clear_env();
    const char *bad[] = {"0", "true", "TRUE", "2", "yes", " 1", "1 ",
                         "on", "  ", "True", "11", "1.0"};
    for (int k = 0; k < (int)(sizeof(bad) / sizeof(bad[0])); k++) {
        SetEnvironmentVariableA(ENV_SKIP_SPLASH, bad[k]);
        relay_parsed_args a = {0};
        relay_config cfg;
        relay_resolve_config(&a, &cfg);
        if (cfg.skip_splash_enabled) {
            ASSERT_FAIL("RELAY_SKIP_SPLASH=\"%s\" should disable, but enabled",
                        bad[k]);
        }
    }
    clear_env();
}

void test_resolve_skip_splash_env_empty_disables(void) {
    /* An explicitly-empty value must disable (not enable). */
    clear_env();
    SetEnvironmentVariableA(ENV_SKIP_SPLASH, "");
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_FALSE(cfg.skip_splash_enabled);
    clear_env();
}

void test_resolve_skip_splash_flag_wins_and_enables_with_invalid_env(void) {
    /* Explicit --skip-splash enables even when the env is set to an invalid
     * value (flag > env). */
    clear_env();
    SetEnvironmentVariableA(ENV_SKIP_SPLASH, "true");
    relay_parsed_args a = {0};
    a.skip_splash_enabled = 1;
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_TRUE(cfg.skip_splash_enabled);
    clear_env();
}

void test_resolve_skip_splash_env_oversized_disables(void) {
    /* An oversized value (would truncate the probe buffer) disables. */
    clear_env();
    char big[32];
    memset(big, '1', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    SetEnvironmentVariableA(ENV_SKIP_SPLASH, big);
    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_FALSE(cfg.skip_splash_enabled);
    clear_env();
}

int main(void) {
    test_register("parse_all_flags", test_parse_all_flags);
    test_register("parse_none", test_parse_none);
    test_register("parse_help_short", test_parse_help_short);
    test_register("parse_help_long", test_parse_help_long);
    test_register("parse_unknown_flag", test_parse_unknown_flag);
    test_register("parse_missing_value", test_parse_missing_value);
    test_register("parse_dash_dash_forwards_tail_in_order",
                  test_parse_dash_dash_forwards_tail_in_order);
    test_register("parse_dash_dash_flag_looking_tokens_not_interpreted",
                  test_parse_dash_dash_flag_looking_tokens_not_interpreted);
    test_register("parse_dash_dash_relay_mod_path_not_set_after_separator",
                  test_parse_dash_dash_relay_mod_path_not_set_after_separator);
    test_register("parse_dash_dash_relay_mod_manager_not_set_after_separator",
                  test_parse_dash_dash_relay_mod_manager_not_set_after_separator);
    test_register("parse_dash_dash_version_not_set_after_separator",
                  test_parse_dash_dash_version_not_set_after_separator);
    test_register("parse_dash_dash_help_not_triggered_after_separator",
                  test_parse_dash_dash_help_not_triggered_after_separator);
    test_register("parse_dash_dash_short_help_not_triggered_after_separator",
                  test_parse_dash_dash_short_help_not_triggered_after_separator);
    test_register("parse_dash_dash_preserves_duplicates",
                  test_parse_dash_dash_preserves_duplicates);
    test_register("parse_dash_dash_with_nothing_after",
                  test_parse_dash_dash_with_nothing_after);
    test_register("parse_no_dash_dash_means_no_game_args",
                  test_parse_no_dash_dash_means_no_game_args);
    test_register("parse_dash_dash_after_regular_flags",
                  test_parse_dash_dash_after_regular_flags);
    test_register("parse_single_value_missing_value_before_dash_dash",
                  test_parse_single_value_missing_value_before_dash_dash);
    test_register("parse_version_before_dash_dash_sets_flag",
                  test_parse_version_before_dash_dash_sets_flag);
    test_register("parse_dash_dash_operator_scenario",
                  test_parse_dash_dash_operator_scenario);
    test_register("version_sets_flag", test_parse_version_sets_flag);
    test_register("version_valueless", test_parse_version_valueless);
    test_register("version_defaults_false", test_parse_version_defaults_false);
    test_register("resolve_flag_wins", test_resolve_flag_wins);
    test_register("resolve_env_when_no_flag", test_resolve_env_when_no_flag);
    test_register("resolve_defaults_when_nothing_set",
                  test_resolve_defaults_when_nothing_set);
    test_register("resolve_mod_path_unset_is_null_with_flag_present",
                  test_resolve_mod_path_unset_is_null_with_flag_present);
    test_register("resolve_mod_manager_flag_wins_over_env",
                  test_resolve_mod_manager_flag_wins_over_env);
    test_register("resolve_mod_manager_env_used_when_no_flag",
                  test_resolve_mod_manager_env_used_when_no_flag);
    test_register("resolve_mod_manager_unset_is_null",
                  test_resolve_mod_manager_unset_is_null);
    test_register("resolve_mod_manager_env_empty_is_null",
                  test_resolve_mod_manager_env_empty_is_null);
    test_register("resolve_mod_manager_env_oversized_refuses",
                  test_resolve_mod_manager_env_oversized_refuses);
    test_register("resolve_mod_manager_env_oversized_ignored_when_flag_present",
                  test_resolve_mod_manager_env_oversized_ignored_when_flag_present);
    test_register("check_mod_manager_not_configured_passes",
                  test_check_mod_manager_not_configured_passes);
    test_register("check_mod_manager_existing_file_passes",
                  test_check_mod_manager_existing_file_passes);
    test_register("check_mod_manager_missing_fails",
                  test_check_mod_manager_missing_fails);
    test_register("check_mod_manager_directory_fails",
                  test_check_mod_manager_directory_fails);
    test_register("derive_game_dir_backslash_path",
                  test_derive_game_dir_backslash_path);
    test_register("derive_game_dir_forward_slashes_preserved",
                  test_derive_game_dir_forward_slashes_preserved);
    test_register("derive_game_dir_mixed_separators",
                  test_derive_game_dir_mixed_separators);
    test_register("derive_game_dir_trailing_separator_tolerated",
                  test_derive_game_dir_trailing_separator_tolerated);
    test_register("derive_game_dir_bare_filename_fails",
                  test_derive_game_dir_bare_filename_fails);
    test_register("derive_game_dir_one_level_fails",
                  test_derive_game_dir_one_level_fails);
    test_register("derive_game_dir_root_relative_empty_prefix_fails",
                  test_derive_game_dir_root_relative_empty_prefix_fails);
    test_register("derive_game_dir_null_and_empty_args",
                  test_derive_game_dir_null_and_empty_args);
    test_register("derive_game_dir_overflow_fails",
                  test_derive_game_dir_overflow_fails);
    test_register("in_game_tree_same_dir_variant_spellings_match",
                  test_in_game_tree_same_dir_variant_spellings_match);
    test_register("in_game_tree_different_dir_does_not_match",
                  test_in_game_tree_different_dir_does_not_match);
    test_register("in_game_tree_nonexistent_mod_path_is_zero",
                  test_in_game_tree_nonexistent_mod_path_is_zero);
    test_register("in_game_tree_null_mod_path_is_zero",
                  test_in_game_tree_null_mod_path_is_zero);
    test_register("in_game_tree_underivable_game_dir_is_zero",
                  test_in_game_tree_underivable_game_dir_is_zero);
    test_register("in_game_tree_mod_path_is_a_file_is_zero",
                  test_in_game_tree_mod_path_is_a_file_is_zero);
    test_register("in_game_tree_symlink_to_game_dir_matches",
                  test_in_game_tree_symlink_to_game_dir_matches);
    test_register("resolve_game_arguments_threaded_unchanged",
                  test_resolve_game_arguments_threaded_unchanged);
    test_register("resolve_game_arguments_none_is_null",
                  test_resolve_game_arguments_none_is_null);
    test_register("parse_log_lua_valueless", test_parse_log_lua_valueless);
    test_register("parse_log_lua_defaults_false", test_parse_log_lua_defaults_false);
    test_register("parse_log_lua_after_dash_dash_is_game_arg",
                  test_parse_log_lua_after_dash_dash_is_game_arg);
    test_register("resolve_log_lua_default_off", test_resolve_log_lua_default_off);
    test_register("resolve_log_lua_env_exact_one_enables",
                  test_resolve_log_lua_env_exact_one_enables);
    test_register("resolve_log_lua_env_other_values_disabled",
                  test_resolve_log_lua_env_other_values_disabled);
    test_register("resolve_log_lua_env_empty_disables",
                  test_resolve_log_lua_env_empty_disables);
    test_register("resolve_log_lua_env_oversized_disables",
                  test_resolve_log_lua_env_oversized_disables);
    test_register("resolve_log_lua_flag_wins_and_enables_with_invalid_env",
                  test_resolve_log_lua_flag_wins_and_enables_with_invalid_env);
    test_register("parse_log_append_valueless", test_parse_log_append_valueless);
    test_register("parse_log_append_defaults_false", test_parse_log_append_defaults_false);
    test_register("parse_log_append_after_dash_dash_is_game_arg",
                  test_parse_log_append_after_dash_dash_is_game_arg);
    test_register("resolve_log_append_default_off", test_resolve_log_append_default_off);
    test_register("resolve_log_append_env_exact_one_enables",
                  test_resolve_log_append_env_exact_one_enables);
    test_register("resolve_log_append_env_other_values_disabled",
                  test_resolve_log_append_env_other_values_disabled);
    test_register("resolve_log_append_env_empty_disables",
                  test_resolve_log_append_env_empty_disables);
    test_register("resolve_log_append_env_oversized_disables",
                  test_resolve_log_append_env_oversized_disables);
    test_register("resolve_log_append_flag_wins_and_enables_with_invalid_env",
                  test_resolve_log_append_flag_wins_and_enables_with_invalid_env);
    test_register("parse_skip_splash_valueless", test_parse_skip_splash_valueless);
    test_register("parse_skip_splash_defaults_false", test_parse_skip_splash_defaults_false);
    test_register("parse_skip_splash_after_dash_dash_is_game_arg",
                  test_parse_skip_splash_after_dash_dash_is_game_arg);
    test_register("resolve_skip_splash_default_off", test_resolve_skip_splash_default_off);
    test_register("resolve_skip_splash_env_exact_one_enables",
                  test_resolve_skip_splash_env_exact_one_enables);
    test_register("resolve_skip_splash_env_other_values_disabled",
                  test_resolve_skip_splash_env_other_values_disabled);
    test_register("resolve_skip_splash_env_empty_disables",
                  test_resolve_skip_splash_env_empty_disables);
    test_register("resolve_skip_splash_flag_wins_and_enables_with_invalid_env",
                  test_resolve_skip_splash_flag_wins_and_enables_with_invalid_env);
    test_register("resolve_skip_splash_env_oversized_disables",
                  test_resolve_skip_splash_env_oversized_disables);
    return test_summary();
}
