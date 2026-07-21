/*
 * test_steam_env.c — Unit tests for launcher's Steam environment setup.
 *
 * Tests that set_steam_env(app_id) correctly sets both SteamAppId and
 * SteamGameId to the supplied app id (was hardcoded; now caller-provided).
 */
#include "test_runner.h"
#include "../launcher/src/launcher.h"
#include <windows.h>
#include <stdio.h>
#include <string.h>

static void cleanup_env(void) {
    /* Clean up after each test so tests don't interfere with each other. */
    SetEnvironmentVariableA("SteamAppId", NULL);
    SetEnvironmentVariableA("SteamGameId", NULL);
}

void test_steam_appid_set(void) {
    cleanup_env();
    set_steam_env("1361210");

    char buf[64];
    DWORD n = GetEnvironmentVariableA("SteamAppId", buf, sizeof(buf));
    ASSERT_TRUE(n > 0 && n < sizeof(buf));
    ASSERT_STREQ("1361210", buf);

    cleanup_env();
}

void test_steam_gameid_set(void) {
    cleanup_env();
    set_steam_env("1361210");

    char buf[64];
    DWORD n = GetEnvironmentVariableA("SteamGameId", buf, sizeof(buf));
    ASSERT_TRUE(n > 0 && n < sizeof(buf));
    ASSERT_STREQ("1361210", buf);

    cleanup_env();
}

void test_both_set_identical(void) {
    cleanup_env();
    set_steam_env("1361210");

    char appId[64], gameId[64];
    DWORD na = GetEnvironmentVariableA("SteamAppId", appId, sizeof(appId));
    DWORD ng = GetEnvironmentVariableA("SteamGameId", gameId, sizeof(gameId));
    ASSERT_TRUE(na > 0 && ng > 0);
    ASSERT_STREQ(appId, gameId);

    cleanup_env();
}

void test_custom_appid_propagated(void) {
    /* The new signature must forward an arbitrary id, not just the Darktide
     * default — this is what makes steam_app_id configurable. */
    cleanup_env();
    set_steam_env("999111");

    char buf[64];
    DWORD n = GetEnvironmentVariableA("SteamAppId", buf, sizeof(buf));
    ASSERT_TRUE(n > 0 && n < sizeof(buf));
    ASSERT_STREQ("999111", buf);

    n = GetEnvironmentVariableA("SteamGameId", buf, sizeof(buf));
    ASSERT_TRUE(n > 0 && n < sizeof(buf));
    ASSERT_STREQ("999111", buf);

    cleanup_env();
}

int main(void) {
    test_register("steam_appid_set", test_steam_appid_set);
    test_register("steam_gameid_set", test_steam_gameid_set);
    test_register("both_set_identical", test_both_set_identical);
    test_register("custom_appid_propagated", test_custom_appid_propagated);
    return test_summary();
}
