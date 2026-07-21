/*
 * test_config.c — Unit tests for the launcher's config model.
 *
 * Validates the two guarantees of the rewrite:
 *   1. relay_parse_args: --flag <value> pairs populate the right fields;
 *      unknown flag / missing value / -h / --help return the right codes.
 *   2. relay_resolve_config: every setting follows flag > env > default,
 *      and RELAY_MOD_PATH resolves to NULL when unset.
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
#define ENV_LOG_FILE     "RELAY_LOG_FILE"
#define ENV_LOG_LEVEL    "RELAY_LOG_LEVEL"
#define ENV_STEAM_APP_ID "RELAY_STEAM_APP_ID"

static void clear_env(void) {
    SetEnvironmentVariableA(ENV_GAME_BINARY, NULL);
    SetEnvironmentVariableA(ENV_MOD_PATH, NULL);
    SetEnvironmentVariableA(ENV_LOG_FILE, NULL);
    SetEnvironmentVariableA(ENV_LOG_LEVEL, NULL);
    SetEnvironmentVariableA(ENV_STEAM_APP_ID, NULL);
}

/* ---- parse_args ---- */

void test_parse_all_flags(void) {
    char *argv[] = {"prog",
        "--game-binary", "G", "--mod-path", "M", "--log-file", "L",
        "--log-level", "trace", "--steam-app-id", "42"};
    relay_parsed_args a;
    ASSERT_EQ(0, relay_parse_args(11, argv, &a));
    ASSERT_STREQ("G", a.game_binary);
    ASSERT_STREQ("M", a.mod_path);
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
    /* First-hand proof of the operator's originally-failing scenario, now
     * correct: --lua-heap-mb-size and 2048 forward as TWO separate tokens. */
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
    SetEnvironmentVariableA(ENV_LOG_FILE, "ENV_LOG");
    SetEnvironmentVariableA(ENV_LOG_LEVEL, "debug");
    SetEnvironmentVariableA(ENV_STEAM_APP_ID, "222");

    relay_parsed_args a = {0};
    relay_config cfg;
    relay_resolve_config(&a, &cfg);
    ASSERT_STREQ("ENV_GAME", cfg.game_binary);
    ASSERT_STREQ("ENV_MOD", cfg.mod_path);
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
    test_register("resolve_game_arguments_threaded_unchanged",
                  test_resolve_game_arguments_threaded_unchanged);
    test_register("resolve_game_arguments_none_is_null",
                  test_resolve_game_arguments_none_is_null);
    return test_summary();
}
