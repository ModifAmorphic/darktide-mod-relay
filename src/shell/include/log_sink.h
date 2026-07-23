/*
 * log_sink.h — pure line-sanitization for the lua-print sink.
 *
 * Converts one untrusted Lua string into a sequence of sanitized, logical log
 * lines, emitted via a caller-supplied callback. CR/LF/CRLF split lines; NUL
 * and other control bytes become the visible \xNN escape (so they cannot forge
 * line structure or terminate a buffer early); % and UTF-8 bytes pass through
 * unchanged as data. No I/O, no heap, no Windows or Lua dependencies — the
 * caller supplies the emit callback (relay_log in the shell; a capturing
 * callback in unit tests). Kept separate from dllmain.c so the sanitization
 * policy is unit-testable, mirroring the pure-helper split in trampoline.h/c.
 */
#ifndef RELAY_LOG_SINK_H
#define RELAY_LOG_SINK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Max input bytes processed per call. Input beyond this is dropped after the
 * emit callback receives exactly one trailing truncation-marker line. Bounds
 * total work regardless of input size. */
#define LOG_SINK_INPUT_BUDGET 4096

/* Max OUTPUT bytes (after control-byte replacement) buffered per physical
 * line. A logical line longer than this is emitted as consecutive chunks,
 * each via a separate emit call. The caller MUST ensure its emit target can
 * accept a line of this width (the shell's relay_log formats into msg[1024],
 * which fits 768 + the "\n" + NUL comfortably). */
#define LOG_SINK_LINE_BUDGET  768

/*
 * Emit callback type: receives one sanitized physical line of exactly `len`
 * bytes per call. `len` is the AUTHORITATIVE boundary — the callback MUST
 * consume `len` (e.g. a "%.*s"-style bounded-precision format narrowing len to
 * int, which is safe since len <= LOG_SINK_LINE_BUDGET), not rely on a NUL
 * terminator. (The renderer does place a NUL at index `len` as a courtesy, but
 * that is incidental; the contract is length-delimited.) The bytes contain no
 * CR, LF, NUL, or other control characters — every byte is printable ASCII
 * (0x20-0x7e) or a preserved data byte (0x80-0xff). `ud` is passed through
 * opaque. Empty lines (len == 0, produced by a bare line terminator) are
 * emitted faithfully. The pointer is only valid for the duration of the call;
 * the callback must not retain it.
 */
typedef void (*log_sink_emit_fn)(const char *line, size_t len, void *ud);

/*
 * Render `input` (len bytes) into sanitized logical log lines, invoking `emit`
 * for each physical line.
 *
 * Line splitting: CR, LF, and CRLF each end the current line. A lone CR or LF
 * is its own break; CRLF is ONE break (the LF following a CR is consumed with
 * it). Empty resulting lines ARE emitted (faithful to print's newline
 * semantics: "a\n\nb" yields "a", "", "b").
 *
 * Byte mapping: bytes 0x00-0x1f (except the terminators handled above) and
 * 0x7f become the 4-byte escape \xNN. All other bytes (0x20-0x7e including %,
 * and 0x80-0xff including UTF-8 lead/continuation bytes) pass through
 * unchanged.
 *
 * Chunking: a line with no terminator that exceeds LOG_SINK_LINE_BUDGET output
 * bytes is emitted as consecutive LOG_SINK_LINE_BUDGET-width chunks (each a
 * separate emit call, so each physical log line still receives its own prefix
 * from the caller).
 *
 * Truncation: if len > LOG_SINK_INPUT_BUDGET, lines are emitted for the first
 * LOG_SINK_INPUT_BUDGET input bytes, then EXACTLY ONE truncation-marker line
 * is emitted (its text begins with '[' and identifies the budget).
 *
 * Pure: no I/O, no heap, no global state. Bounded stack (one
 * (LOG_SINK_LINE_BUDGET + 1)-byte work buffer). Returns nothing; all output
 * goes through `emit`. A NULL `input` or `emit` is a no-op.
 */
void log_sink_render(const char *input, size_t len,
                     log_sink_emit_fn emit, void *ud);

#ifdef __cplusplus
}
#endif

#endif /* RELAY_LOG_SINK_H */
