/*
 * test_quoting.c — Unit tests for relay_build_command_line().
 *
 * Two layers of assertion, as required by the item brief:
 *
 *   1. Exact-byte spine — assert the built command line equals a hand-written
 *      expected string. This is the deterministic backward-compat backbone
 *      (esp. the zero-arg case, which must be byte-for-byte the legacy
 *      "\"%s\"" form).
 *
 *   2. CommandLineToArgvW round-trip oracle — convert the built ANSI line to
 *      wide (CP_ACP; all test values are ASCII so the conversion is lossless),
 *      hand it to the OS's OWN argv parser (CommandLineToArgvW), and assert
 *      it re-parses back to exactly: the exe as argv[0], then each original
 *      game-argument token in order. This is the real correctness check: it
 *      proves the bytes actually round-trip through Windows' CRT parser, not
 *      just through my expectations.
 *
 * CommandLineToArgvW implements the same MSVC CRT rules the builder targets,
 * so a passing round-trip is direct evidence the quoting is correct.
 */
#include "test_runner.h"
#include "../launcher/src/launcher.h"
#include <windows.h>
#include <shellapi.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* The exe used as argv[0] for every case. C:\\g\\Darktide.exe — backslashes
 * but no U+0022, so it re-parses verbatim under the CRT rules (backslashes
 * not followed by a " are literal). */
#define EXE "C:\\g\\Darktide.exe"

/* ---- helpers ---- */

/* Build with the standard exe into a generous buffer; ASSERTs on failure.
 * The built line is left in buf for the caller to inspect. */
static void build(const char *const *args, int count, char *buf,
                  size_t bufsize) {
    if (relay_build_command_line(EXE, args, count, buf, bufsize) != 0) {
        ASSERT_FAIL("relay_build_command_line returned -1 (overflow?) for "
                    "count=%d bufsize=%zu", count, bufsize);
    }
}

/* Compare a wide string (from CommandLineToArgvW) to an ANSI expected string
 * by converting the expected to wide via CP_ACP. Returns 1 if equal. */
static int wstr_eq_ansi(const wchar_t *actual, const char *expected) {
    int wlen = MultiByteToWideChar(CP_ACP, 0, expected, -1, NULL, 0);
    if (wlen <= 0) return 0;
    wchar_t *w = malloc((size_t)wlen * sizeof(wchar_t));
    if (!w) return 0;
    MultiByteToWideChar(CP_ACP, 0, expected, -1, w, wlen);
    int eq = (wcscmp(actual, w) == 0);
    free(w);
    return eq;
}

/* The round-trip oracle: build the line for [exe + args], parse it back with
 * CommandLineToArgvW, and assert it equals exe followed by the original args.
 * ASSERTs on any mismatch. */
static void roundtrip(const char *const *args, int count) {
    char buf[RELAY_CMDLINE_MAX];
    build(args, count, buf, sizeof(buf));

    /* ANSI -> wide (CP_ACP). All test values are ASCII, so lossless. */
    int wlen = MultiByteToWideChar(CP_ACP, 0, buf, -1, NULL, 0);
    if (wlen <= 0) ASSERT_FAIL("MultiByteToWideChar len failed");
    wchar_t *wide = malloc((size_t)wlen * sizeof(wchar_t));
    if (!wide) ASSERT_FAIL("out of memory");
    MultiByteToWideChar(CP_ACP, 0, buf, -1, wide, wlen);

    int argc = 0;
    LPWSTR *parsed = CommandLineToArgvW(wide, &argc);
    free(wide);
    if (parsed == NULL) {
        ASSERT_FAIL("CommandLineToArgvW returned NULL (GLE=%lu)",
                    GetLastError());
    }

    ASSERT_EQ(count + 1, argc);
    if (!wstr_eq_ansi(parsed[0], EXE)) {
        ASSERT_FAIL("argv[0] mismatch after round-trip");
    }
    for (int i = 0; i < count; i++) {
        if (!wstr_eq_ansi(parsed[i + 1], args[i])) {
            ASSERT_FAIL("argv[%d] mismatch after round-trip", i + 1);
        }
    }
    LocalFree(parsed);
}

/* ---- exact-byte spine ---- */

void test_zero_args_is_legacy_form(void) {
    char buf[RELAY_CMDLINE_MAX];
    build(NULL, 0, buf, sizeof(buf));
    ASSERT_STREQ("\"C:\\g\\Darktide.exe\"", buf);
}

void test_one_bare_arg(void) {
    char buf[RELAY_CMDLINE_MAX];
    const char *args[] = {"-foo"};
    build(args, 1, buf, sizeof(buf));
    ASSERT_STREQ("\"C:\\g\\Darktide.exe\" -foo", buf);
}

void test_arg_with_spaces_quoted(void) {
    char buf[RELAY_CMDLINE_MAX];
    const char *args[] = {"value with spaces"};
    build(args, 1, buf, sizeof(buf));
    ASSERT_STREQ("\"C:\\g\\Darktide.exe\" \"value with spaces\"", buf);
}

void test_arg_with_tab_quoted(void) {
    char buf[RELAY_CMDLINE_MAX];
    const char *args[] = {"a\tb"};
    build(args, 1, buf, sizeof(buf));
    ASSERT_STREQ("\"C:\\g\\Darktide.exe\" \"a\tb\"", buf);
}

void test_empty_arg_emits_empty_quotes(void) {
    char buf[RELAY_CMDLINE_MAX];
    const char *args[] = {""};
    build(args, 1, buf, sizeof(buf));
    ASSERT_STREQ("\"C:\\g\\Darktide.exe\" \"\"", buf);
}

void test_embedded_quote_escaped(void) {
    char buf[RELAY_CMDLINE_MAX];
    const char *args[] = {"he\"llo"};
    /* token he"llo -> "he\"llo" (the " becomes \") */
    build(args, 1, buf, sizeof(buf));
    ASSERT_STREQ("\"C:\\g\\Darktide.exe\" \"he\\\"llo\"", buf);
}

void test_backslash_before_quote(void) {
    char buf[RELAY_CMDLINE_MAX];
    /* token bytes: a \ " b  -> render -> "a\\\"b" (3 backslashes before ").
     * Expected written with OCTAL escapes (\042=", \134=\) because octal is
     * bounded to 3 digits — hex (\x22) would greedily swallow the following
     * 'D'/'b' hex digits. */
    const char *args[] = {"a\\\"b"};
    build(args, 1, buf, sizeof(buf));
    ASSERT_STREQ("\042C:\134g\134Darktide.exe\042 \042a\134\134\134\042b\042",
                 buf);
}

void test_trailing_backslash_doubled(void) {
    char buf[RELAY_CMDLINE_MAX];
    /* token bytes: x SPACE \  -> quoted, trailing \ doubled -> "x \\"
     * (the single trailing backslash is doubled because it precedes the
     * closing "). Expected in OCTAL escapes (\042=", \134=\). */
    const char *args[] = {"x \\"};
    build(args, 1, buf, sizeof(buf));
    ASSERT_STREQ("\042C:\134g\134Darktide.exe\042 \042x \134\134\042", buf);
}

void test_multiple_args_preserve_order_and_dups(void) {
    char buf[RELAY_CMDLINE_MAX];
    const char *args[] = {"-x", "-x", "y z"};
    build(args, 3, buf, sizeof(buf));
    ASSERT_STREQ("\"C:\\g\\Darktide.exe\" -x -x \"y z\"", buf);
}

void test_oversize_rejected(void) {
    /* The zero-arg line is "\"C:\\g\\Darktide.exe\"" (20 chars + NUL = 21).
     * A buffer smaller than that must overflow -> -1.
     * NOTE: avoid the bare name `small` — the Windows SDK headers
     * (pulled in transitively via <windows.h>) `#define small char`, which
     * would expand `char small[8]` to `char char[8]` and fail to compile
     * under MSVC. */
    char small_buf[8];
    ASSERT_EQ(-1, relay_build_command_line(EXE, NULL, 0, small_buf, sizeof(small_buf)));
}

void test_null_exe_rejected(void) {
    char buf[RELAY_CMDLINE_MAX];
    ASSERT_EQ(-1, relay_build_command_line(NULL, NULL, 0, buf, sizeof(buf)));
}

/* ---- CommandLineToArgvW round-trip oracle (the real correctness check) ---- */

void test_roundtrip_zero_args(void) {
    roundtrip(NULL, 0);
}

void test_roundtrip_bare_and_spaced(void) {
    const char *args[] = {"-foo", "value with spaces", "plain"};
    roundtrip(args, 3);
}

void test_roundtrip_tab_and_empty(void) {
    const char *args[] = {"a\tb", "", "c"};
    roundtrip(args, 3);
}

void test_roundtrip_embedded_quote(void) {
    const char *args[] = {"he\"llo", "a\"b\"c"};
    roundtrip(args, 2);
}

void test_roundtrip_backslash_before_quote(void) {
    /* a\"b (a \ " b), and a path-like \\server\share\"x */
    const char *args[] = {"a\\\"b", "\\\\server\\share\\\"x"};
    roundtrip(args, 2);
}

void test_roundtrip_trailing_backslash(void) {
    const char *args[] = {"x \\", "trailing\\", "ends with space \\\""};
    roundtrip(args, 3);
}

void test_roundtrip_pure_backslashes(void) {
    /* Bare tokens of backslashes (no space/tab/") are emitted verbatim and
     * re-parse literally because no backslash is followed by a ". */
    const char *args[] = {"\\", "\\\\", "\\\\\\"};
    roundtrip(args, 3);
}

void test_roundtrip_duplicates_preserved(void) {
    const char *args[] = {"-x", "-x", "y z", "-x"};
    roundtrip(args, 4);
}

void test_roundtrip_darktide_production_line(void) {
    /* The validated production command line:
     *   <exe> --bundle-dir ../bundle --ini settings
     *         --backend-auth-service-url <url> --backend-title-service-url <url>
     * All ASCII. */
    const char *args[] = {
        "--bundle-dir", "../bundle",
        "--ini", "settings",
        "--backend-auth-service-url", "https://auth.example.com/auth",
        "--backend-title-service-url", "https://title.example.com/title",
    };
    roundtrip(args, 8);
}

void test_roundtrip_fits_just_under_ceiling(void) {
    /* A long but legal argument that must NOT overflow and must round-trip.
     * The builder buffer is RELAY_CMDLINE_MAX; the token itself is long but
     * fits well under the ceiling. Exercises the per-byte overflow check on a
     * non-trivial length. */
    char longarg[4000];
    memset(longarg, 'a', sizeof(longarg) - 1);
    longarg[sizeof(longarg) - 1] = '\0';
    const char *args[] = {longarg};
    roundtrip(args, 1);
}

void test_oversize_at_ceiling_rejected(void) {
    /* An argument long enough to overflow RELAY_CMDLINE_MAX must be rejected
     * with -1 (never silently truncated, never passed to CreateProcessA). */
    char huge[RELAY_CMDLINE_MAX + 256];
    memset(huge, 'b', sizeof(huge) - 1);
    huge[sizeof(huge) - 1] = '\0';
    const char *args[] = {huge};
    char buf[RELAY_CMDLINE_MAX];
    ASSERT_EQ(-1, relay_build_command_line(EXE, args, 1, buf, sizeof(buf)));
}

int main(void) {
    /* exact-byte spine */
    test_register("zero_args_is_legacy_form", test_zero_args_is_legacy_form);
    test_register("one_bare_arg", test_one_bare_arg);
    test_register("arg_with_spaces_quoted", test_arg_with_spaces_quoted);
    test_register("arg_with_tab_quoted", test_arg_with_tab_quoted);
    test_register("empty_arg_emits_empty_quotes", test_empty_arg_emits_empty_quotes);
    test_register("embedded_quote_escaped", test_embedded_quote_escaped);
    test_register("backslash_before_quote", test_backslash_before_quote);
    test_register("trailing_backslash_doubled", test_trailing_backslash_doubled);
    test_register("multiple_args_preserve_order_and_dups",
                  test_multiple_args_preserve_order_and_dups);
    test_register("oversize_rejected", test_oversize_rejected);
    test_register("null_exe_rejected", test_null_exe_rejected);
    /* CommandLineToArgvW round-trip oracle */
    test_register("roundtrip_zero_args", test_roundtrip_zero_args);
    test_register("roundtrip_bare_and_spaced", test_roundtrip_bare_and_spaced);
    test_register("roundtrip_tab_and_empty", test_roundtrip_tab_and_empty);
    test_register("roundtrip_embedded_quote", test_roundtrip_embedded_quote);
    test_register("roundtrip_backslash_before_quote",
                  test_roundtrip_backslash_before_quote);
    test_register("roundtrip_trailing_backslash", test_roundtrip_trailing_backslash);
    test_register("roundtrip_pure_backslashes", test_roundtrip_pure_backslashes);
    test_register("roundtrip_duplicates_preserved",
                  test_roundtrip_duplicates_preserved);
    test_register("roundtrip_darktide_production_line",
                  test_roundtrip_darktide_production_line);
    test_register("roundtrip_fits_just_under_ceiling",
                  test_roundtrip_fits_just_under_ceiling);
    test_register("oversize_at_ceiling_rejected", test_oversize_at_ceiling_rejected);
    return test_summary();
}
