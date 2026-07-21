/*
 * test_runner.c — Minimal C unit-test harness implementation.
 *
 * Supports up to 64 registered tests. Tests are registered via
 * test_register() and executed in order. On MSVC, unhandled exceptions
 * during a test are caught via SEH; on MinGW the process will abort
 * (still reported as a failure by the exit code).
 */
#include "test_runner.h"
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define MAX_TESTS 64

typedef struct {
    const char *name;
    void (*fn)(void);
    int passed;       /* 0 = failed, 1 = passed */
    int ran;          /* was the test executed? */
} test_entry_t;

static test_entry_t tests[MAX_TESTS];
static int ntests = 0;
static int current_failed = 0;  /* set by ASSERT_* macros */

void test_register(const char *name, void (*fn)(void)) {
    if (ntests >= MAX_TESTS) {
        fprintf(stderr, "test_runner: too many tests (max %d)\n", MAX_TESTS);
        return;
    }
    tests[ntests].name = name;
    tests[ntests].fn = fn;
    tests[ntests].passed = 0;
    tests[ntests].ran = 0;
    ntests++;
}

/* Called by ASSERT_* macros to mark the current test as failed. */
void test_failed(void) {
    current_failed = 1;
}

int test_summary(void) {
    int passed = 0, failed = 0, total = 0;

    for (int i = 0; i < ntests; i++) {
        current_failed = 0;

#ifdef _MSC_VER
        /* MSVC: catch SE exceptions to prevent test crashes from killing
         * the entire harness. */
        __try {
            tests[i].fn();
            tests[i].ran = 1;
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            tests[i].ran = 1;
            current_failed = 1;
        }
#else
        /* MinGW / other: run directly. A crash will terminate the process
         * with a non-zero exit code, which still counts as a failure. */
        tests[i].fn();
        tests[i].ran = 1;
#endif

        if (!current_failed) {
            tests[i].passed = 1;
            passed++;
            printf("  PASS: %s\n", tests[i].name);
        } else {
            failed++;
            printf("  FAIL: %s\n", tests[i].name);
        }
        total++;
    }

    printf("\n--- %d/%d tests passed ---\n", passed, total);
    return (failed > 0) ? 1 : 0;
}
