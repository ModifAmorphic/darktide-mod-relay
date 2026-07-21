/*
 * test_runner.h — Minimal C unit-test harness (no external deps).
 *
 * Usage in a test file:
 *   #include "test_runner.h"
 *
 *   void test_foo(void) {
 *       ASSERT_STREQ("hello", get_greeting());
 *   }
 *
 *   int main(void) {
 *       RUN_TEST(test_foo);
 *       return test_summary();
 *   }
 */
#ifndef RELAY_TEST_RUNNER_H
#define RELAY_TEST_RUNNER_H

/* Register a named test function. Call once per test, before main() runs. */
void test_register(const char *name, void (*fn)(void));

/* Called by ASSERT_* macros to mark the current test as failed. */
void test_failed(void);

/* Return 0 if all registered tests passed, 1 otherwise. Prints a summary. */
int test_summary(void);

/* ---- assertion macros ---- */

/* Fail the current test with a formatted message. */
#define ASSERT_FAIL(fmt, ...) \
    do { \
        fprintf(stderr, "  FAIL at %s:%d: " fmt "\n", \
                __FILE__, __LINE__, ##__VA_ARGS__); \
        test_failed(); \
        return; \
    } while (0)

/* Generic equality assertion for integers. */
#define ASSERT_EQ(expected, actual) \
    do { \
        long _e = (long)(expected); \
        long _a = (long)(actual); \
        if (_e != _a) \
            ASSERT_FAIL("expected %ld, got %ld", _e, _a); \
    } while (0)

/* String equality assertion. */
#define ASSERT_STREQ(expected, actual) \
    do { \
        const char *_e = (expected); \
        const char *_a = (actual); \
        if (!_e || !_a || strcmp(_e, _a) != 0) \
            ASSERT_FAIL("expected \"%s\", got \"%s\"", _e, _a); \
    } while (0)

/* Non-null pointer assertion. */
#define ASSERT_NOTNULL(expr) \
    do { \
        void *_p = (void *)(expr); \
        if (!_p) \
            ASSERT_FAIL("expected non-NULL, got NULL"); \
    } while (0)

/* Truthiness assertion. */
#define ASSERT_TRUE(expr) \
    do { \
        if (!(expr)) \
            ASSERT_FAIL("expected true, got false"); \
    } while (0)

/* Falseness assertion. */
#define ASSERT_FALSE(expr) \
    do { \
        if (expr) \
            ASSERT_FAIL("expected false, got true"); \
    } while (0)

#endif /* RELAY_TEST_RUNNER_H */
