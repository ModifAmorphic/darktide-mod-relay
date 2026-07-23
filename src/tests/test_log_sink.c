/*
 * test_log_sink.c — Unit tests for the pure lua-print line sanitizer.
 *
 * Covers line splitting (LF/CR/CRLF), control-byte replacement (NUL + others),
 * passthrough (% and UTF-8), empty-line faithfulness, long-line chunking, and
 * the single truncation marker. Compiles log_sink.c directly (no Windows/Lua
 * deps), mirroring test_trampoline.c's pattern.
 */
#include "test_runner.h"
#include "../shell/src/log_sink.c"  /* compile the pure impl directly */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ---- capture harness ---- */

#define CAP_MAX_LINES 256
#define CAP_LINE_MAX  1200
typedef struct {
    char lines[CAP_MAX_LINES][CAP_LINE_MAX];
    size_t lens[CAP_MAX_LINES];
    int count;
} cap_t;

static void cap_emit(const char *line, size_t len, void *ud) {
    cap_t *c = (cap_t *)ud;
    if (c->count >= CAP_MAX_LINES) return;
    if (len >= CAP_LINE_MAX) len = CAP_LINE_MAX - 1;
    memcpy(c->lines[c->count], line, len);
    c->lines[c->count][len] = '\0';
    c->lens[c->count] = len;
    c->count++;
}

static void cap_reset(cap_t *c) {
    c->count = 0;
}

static void cap_expect_one(cap_t *c, const char *expected) {
    ASSERT_EQ(1, c->count);
    ASSERT_STREQ(expected, c->lines[0]);
}

/* ---- single-line passthrough ---- */

void test_plain_string_one_line(void) {
    cap_t c; cap_reset(&c);
    log_sink_render("hello", 5, cap_emit, &c);
    cap_expect_one(&c, "hello");
}

void test_percent_preserved(void) {
    /* % must survive as data (the caller uses it as a %s argument, never as a
     * format string, so % in the data is literal). */
    cap_t c; cap_reset(&c);
    const char *s = "100%done %s %d";
    log_sink_render(s, strlen(s), cap_emit, &c);
    cap_expect_one(&c, "100%done %s %d");
}

void test_utf8_preserved(void) {
    /* UTF-8 lead (0xc3) + continuation (0xa9) = é; both >= 0x80, pass through. */
    cap_t c; cap_reset(&c);
    log_sink_render("\xc3\xa9\xe2\x9c\x93", 5, cap_emit, &c);  /* é ✓ */
    cap_expect_one(&c, "\xc3\xa9\xe2\x9c\x93");
}

void test_empty_input_emits_nothing(void) {
    cap_t c; cap_reset(&c);
    log_sink_render("", 0, cap_emit, &c);
    ASSERT_EQ(0, c.count);
}

/* ---- line splitting ---- */

void test_lf_splits(void) {
    cap_t c; cap_reset(&c);
    log_sink_render("a\nb", 3, cap_emit, &c);
    ASSERT_EQ(2, c.count);
    ASSERT_STREQ("a", c.lines[0]);
    ASSERT_STREQ("b", c.lines[1]);
}

void test_cr_splits(void) {
    cap_t c; cap_reset(&c);
    log_sink_render("a\rb", 3, cap_emit, &c);
    ASSERT_EQ(2, c.count);
    ASSERT_STREQ("a", c.lines[0]);
    ASSERT_STREQ("b", c.lines[1]);
}

void test_crlf_is_one_break(void) {
    /* CRLF must be ONE line break, not two (no spurious empty line). */
    cap_t c; cap_reset(&c);
    log_sink_render("a\r\nb", 4, cap_emit, &c);
    ASSERT_EQ(2, c.count);
    ASSERT_STREQ("a", c.lines[0]);
    ASSERT_STREQ("b", c.lines[1]);
}

void test_empty_lines_preserved(void) {
    /* "a\n\nb" -> "a", "", "b" (the bare LF yields a faithful empty line). */
    cap_t c; cap_reset(&c);
    log_sink_render("a\n\nb", 4, cap_emit, &c);
    ASSERT_EQ(3, c.count);
    ASSERT_STREQ("a", c.lines[0]);
    ASSERT_STREQ("", c.lines[1]);
    ASSERT_EQ(0, c.lens[1]);
    ASSERT_STREQ("b", c.lines[2]);
}

void test_trailing_lf_emits_no_extra_empty(void) {
    /* "a\n" -> "a" (one line; the trailing terminator ends "a", no trailing
     * empty line is synthesized). */
    cap_t c; cap_reset(&c);
    log_sink_render("a\n", 2, cap_emit, &c);
    ASSERT_EQ(1, c.count);
    ASSERT_STREQ("a", c.lines[0]);
}

void test_bare_lf_emits_one_empty_line(void) {
    cap_t c; cap_reset(&c);
    log_sink_render("\n", 1, cap_emit, &c);
    ASSERT_EQ(1, c.count);
    ASSERT_EQ(0, c.lens[0]);
}

void test_crlf_only_emits_one_empty_line(void) {
    cap_t c; cap_reset(&c);
    log_sink_render("\r\n", 2, cap_emit, &c);
    ASSERT_EQ(1, c.count);
    ASSERT_EQ(0, c.lens[0]);
}

/* ---- control-byte replacement ---- */

void test_nul_replaced(void) {
    /* Embedded NUL must become \x00 (4 visible bytes), not terminate the line. */
    cap_t c; cap_reset(&c);
    log_sink_render("a\x00""b", 3, cap_emit, &c);
    cap_expect_one(&c, "a\\x00b");
    ASSERT_EQ(6, c.lens[0]);  /* a + \x00 + b = 6 bytes */
}

void test_control_bytes_replaced(void) {
    cap_t c; cap_reset(&c);
    log_sink_render("\x01\x02\x1f", 3, cap_emit, &c);
    cap_expect_one(&c, "\\x01\\x02\\x1f");
}

void test_tab_replaced(void) {
    /* 0x09 is a control byte (< 0x20), not a terminator -> \x09. */
    cap_t c; cap_reset(&c);
    log_sink_render("a\tb", 3, cap_emit, &c);
    cap_expect_one(&c, "a\\x09b");
}

void test_del_replaced(void) {
    /* 0x7f (DEL) -> \x7f. */
    cap_t c; cap_reset(&c);
    log_sink_render("a\x7f""b", 3, cap_emit, &c);
    cap_expect_one(&c, "a\\x7fb");
}

void test_high_bytes_pass_through(void) {
    /* 0x80-0xff are not control bytes; they pass through (UTF-8 / raw data). */
    cap_t c; cap_reset(&c);
    log_sink_render("\x80\xff\xfe", 3, cap_emit, &c);
    cap_expect_one(&c, "\x80\xff\xfe");
}

void test_no_embedded_nul_or_control_in_output(void) {
    /* Sweep every byte value; confirm no output line ever contains a raw
     * control byte or NUL (the whole point of the sanitizer). Terminators
     * become line splits, not output bytes. */
    char in[256];
    for (int b = 0; b < 256; b++) in[b] = (char)b;
    cap_t c; cap_reset(&c);
    log_sink_render(in, 256, cap_emit, &c);
    for (int k = 0; k < c.count; k++) {
        for (size_t j = 0; j < c.lens[k]; j++) {
            unsigned char x = (unsigned char)c.lines[k][j];
            /* Output bytes must be printable ASCII (0x20-0x7e) or high (0x80-0xff).
             * No 0x00-0x1f, no 0x7f. (Backslash and x and hex digits are all in
             * 0x20-0x7e.) */
            ASSERT_FALSE(x < 0x20 || x == 0x7f);
        }
    }
}

/* ---- chunking + truncation ---- */

void test_long_line_chunked(void) {
    /* A line longer than LINE_BUDGET (with no terminator) is emitted in
     * consecutive LINE_BUDGET-width chunks, each its own line. */
    char in[LOG_SINK_LINE_BUDGET + 100];
    memset(in, 'X', sizeof(in));
    cap_t c; cap_reset(&c);
    log_sink_render(in, sizeof(in), cap_emit, &c);
    ASSERT_EQ(2, c.count);
    ASSERT_EQ((size_t)LOG_SINK_LINE_BUDGET, c.lens[0]);
    ASSERT_EQ((size_t)100, c.lens[1]);
}

void test_truncation_marker_emitted_once(void) {
    /* Input exceeding INPUT_BUDGET yields exactly one trailing marker line. */
    size_t n = LOG_SINK_INPUT_BUDGET + 50;
    char *in = malloc(n);
    ASSERT_NOTNULL(in);
    memset(in, 'A', n);
    cap_t c; cap_reset(&c);
    log_sink_render(in, n, cap_emit, &c);
    free(in);
    /* First chunk is the budget-width line of A's. */
    ASSERT_EQ((size_t)LOG_SINK_LINE_BUDGET, c.lens[0]);
    /* Final line is the truncation marker. */
    ASSERT_TRUE(strstr(c.lines[c.count - 1], "truncated") != NULL);
    ASSERT_TRUE(strstr(c.lines[c.count - 1], "budget") != NULL);
    /* Exactly one marker: no other line mentions truncation. */
    int markers = 0;
    for (int k = 0; k < c.count; k++) {
        if (strstr(c.lines[k], "truncated")) markers++;
    }
    ASSERT_EQ(1, markers);
}

void test_truncation_marker_only(void) {
    /* An empty input under budget has no marker; an input OVER budget always
     * has exactly one. This test pins the boundary: exactly budget bytes -> no
     * marker; budget+1 -> one marker. */
    char *in = malloc(LOG_SINK_INPUT_BUDGET + 1);
    ASSERT_NOTNULL(in);

    memset(in, 'A', LOG_SINK_INPUT_BUDGET);
    cap_t c1; cap_reset(&c1);
    log_sink_render(in, LOG_SINK_INPUT_BUDGET, cap_emit, &c1);
    int m1 = 0;
    for (int k = 0; k < c1.count; k++) if (strstr(c1.lines[k], "truncated")) m1++;
    ASSERT_EQ(0, m1);

    memset(in, 'A', LOG_SINK_INPUT_BUDGET + 1);
    cap_t c2; cap_reset(&c2);
    log_sink_render(in, LOG_SINK_INPUT_BUDGET + 1, cap_emit, &c2);
    int m2 = 0;
    for (int k = 0; k < c2.count; k++) if (strstr(c2.lines[k], "truncated")) m2++;
    ASSERT_EQ(1, m2);

    free(in);
}

int main(void) {
    test_register("plain_string_one_line", test_plain_string_one_line);
    test_register("percent_preserved", test_percent_preserved);
    test_register("utf8_preserved", test_utf8_preserved);
    test_register("empty_input_emits_nothing", test_empty_input_emits_nothing);
    test_register("lf_splits", test_lf_splits);
    test_register("cr_splits", test_cr_splits);
    test_register("crlf_is_one_break", test_crlf_is_one_break);
    test_register("empty_lines_preserved", test_empty_lines_preserved);
    test_register("trailing_lf_emits_no_extra_empty",
                  test_trailing_lf_emits_no_extra_empty);
    test_register("bare_lf_emits_one_empty_line",
                  test_bare_lf_emits_one_empty_line);
    test_register("crlf_only_emits_one_empty_line",
                  test_crlf_only_emits_one_empty_line);
    test_register("nul_replaced", test_nul_replaced);
    test_register("control_bytes_replaced", test_control_bytes_replaced);
    test_register("tab_replaced", test_tab_replaced);
    test_register("del_replaced", test_del_replaced);
    test_register("high_bytes_pass_through", test_high_bytes_pass_through);
    test_register("no_embedded_nul_or_control_in_output",
                  test_no_embedded_nul_or_control_in_output);
    test_register("long_line_chunked", test_long_line_chunked);
    test_register("truncation_marker_emitted_once",
                  test_truncation_marker_emitted_once);
    test_register("truncation_marker_only", test_truncation_marker_only);
    return test_summary();
}
