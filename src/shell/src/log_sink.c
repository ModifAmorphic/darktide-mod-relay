/*
 * log_sink.c — pure line-sanitization for the lua-print sink.
 *
 * Implementation of the helper declared in log_sink.h. This file has NO
 * Windows, Lua, or hook dependencies — only string/snprintf ops — so it
 * compiles directly into both the shell DLL and the C unit-test exes (like
 * trampoline.c). The shell's dllmain.c calls log_sink_render with a relay_log-
 * emitting callback; the callback owns the structured-log prefix.
 */
#include "log_sink.h"

#include <stdio.h>
#include <string.h>

void log_sink_render(const char *input, size_t len,
                     log_sink_emit_fn emit, void *ud) {
    if (!input || !emit) return;

    /* +1 so a full-width line (fill == LINE_BUDGET) can still be NUL-
     * terminated in place before each emit call (the callback receives a
     * proper C string and never has to copy). fill never exceeds
     * LINE_BUDGET: the overflow check flushes before a replacement would
     * cross the boundary. */
    char line[LOG_SINK_LINE_BUDGET + 1];
    size_t fill = 0;
    size_t i = 0;
    int truncated = 0;

    while (i < len) {
        if (i >= LOG_SINK_INPUT_BUDGET) { truncated = 1; break; }
        unsigned char c = (unsigned char)input[i];

        /* Line terminators flush the current line. CRLF is one break (the LF
         * following a CR is consumed with it); a lone CR or LF is its own
         * break. Empty resulting lines are emitted (fill may be 0). */
        if (c == '\r') {
            line[fill] = '\0';
            emit(line, fill, ud);
            fill = 0;
            i++;
            if (i < len && (unsigned char)input[i] == '\n') i++;  /* CRLF pair */
            continue;
        }
        if (c == '\n') {
            line[fill] = '\0';
            emit(line, fill, ud);
            fill = 0;
            i++;
            continue;
        }

        /* Map each input byte to its sanitized replacement. Control bytes
         * (0x00-0x1f except the terminators handled above, plus 0x7f) become
         * the 4-byte visible escape \xNN — so embedded NUL can't terminate a
         * buffer and no control byte can forge line structure. snprintf with a
         * 5-byte dest always writes exactly 4 bytes + NUL for a 0-255 value.
         * % (0x25) and ordinary UTF-8 bytes (>= 0x20, incl. 0x80-0xff) pass
         * through unchanged as data. */
        char esc[5];
        const char *repl;
        size_t repl_len;
        if (c < 0x20 || c == 0x7f) {
            snprintf(esc, sizeof(esc), "\\x%02x", c);  /* 4 bytes + NUL */
            repl = esc;
            repl_len = 4;
        } else {
            esc[0] = (char)c;
            repl = esc;
            repl_len = 1;
        }

        /* Flush first if this replacement would cross the line boundary. A
         * single replacement (<= 4 bytes) always fits in the empty buffer
         * (LINE_BUDGET = 768), so no special-case is needed after the flush. */
        if (fill + repl_len > LOG_SINK_LINE_BUDGET) {
            line[fill] = '\0';
            emit(line, fill, ud);
            fill = 0;
        }
        memcpy(line + fill, repl, repl_len);
        fill += repl_len;
        i++;
    }

    /* Trailing partial line (input with no trailing terminator). */
    if (fill > 0) {
        line[fill] = '\0';
        emit(line, fill, ud);
    }

    if (truncated) {
        char marker[64];
        int n = snprintf(marker, sizeof(marker),
                         "[input exceeded %d-byte budget; truncated]",
                         LOG_SINK_INPUT_BUDGET);
        if (n > 0 && (size_t)n < sizeof(marker)) {
            emit(marker, (size_t)n, ud);
        }
    }
}
