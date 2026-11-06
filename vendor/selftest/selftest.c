/* The test-only vendor library: it exercises everything the module interface
 * carries, so the recipe is proven without a real library. It never ships. */
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "../emerald_module.h"

static char scratch[4096];

static EmValue fail(const char *message) {
    return em_error(message, strlen(message));
}

static EmValue add(const EmValue *a, size_t n) {
    (void)n;
    return em_int(a[0].as.integer + a[1].as.integer);
}

static EmValue halve(const EmValue *a, size_t n) {
    (void)n;
    return em_float(a[0].as.number / 2.0);
}

static EmValue invert(const EmValue *a, size_t n) {
    (void)n;
    return em_bool(!a[0].as.boolean);
}

static EmValue shout(const EmValue *a, size_t n) {
    (void)n;
    size_t length = a[0].as.bytes.length;
    if (length > sizeof scratch) return fail("that text is too long for the selftest library");
    for (size_t i = 0; i < length; i++) {
        unsigned char c = a[0].as.bytes.data[i];
        scratch[i] = (c < 128) ? (char)toupper(c) : (char)c;
    }
    return em_text(scratch, length);
}

static EmValue reverse_bytes(const EmValue *a, size_t n) {
    (void)n;
    size_t length = a[0].as.bytes.length;
    if (length > sizeof scratch) return fail("those bytes are too long for the selftest library");
    for (size_t i = 0; i < length; i++) scratch[i] = (char)a[0].as.bytes.data[length - 1 - i];
    return em_bytes((const uint8_t *)scratch, length);
}

static EmValue ping(const EmValue *a, size_t n) {
    (void)a;
    (void)n;
    return em_nothing();
}

static EmValue always_fails(const EmValue *a, size_t n) {
    (void)a;
    (void)n;
    return fail("the selftest library always fails here\nIt exists to test Emerald, so it fails on purpose.");
}

/* Counters: an opaque resource held as an integer handle. */
#define MAX_COUNTERS 16
static int64_t counters[MAX_COUNTERS];
static int open_counters[MAX_COUNTERS];

static EmValue counter_open(const EmValue *a, size_t n) {
    (void)n;
    for (int i = 0; i < MAX_COUNTERS; i++) {
        if (!open_counters[i]) {
            open_counters[i] = 1;
            counters[i] = a[0].as.integer;
            return em_int(i + 1);
        }
    }
    return fail("all the selftest counters are in use");
}

static int live(int64_t handle) {
    return handle >= 1 && handle <= MAX_COUNTERS && open_counters[handle - 1];
}

static EmValue counter_next(const EmValue *a, size_t n) {
    (void)n;
    if (!live(a[0].as.integer)) return fail("that counter is closed\nOpen a new one with `Selftest.counter()`.");
    return em_int(++counters[a[0].as.integer - 1]);
}

static EmValue counter_close(const EmValue *a, size_t n) {
    (void)n;
    if (!live(a[0].as.integer)) return fail("that counter is closed\nOpen a new one with `Selftest.counter()`.");
    open_counters[a[0].as.integer - 1] = 0;
    return em_nothing();
}

static EmValue open_count(const EmValue *a, size_t n) {
    (void)a;
    (void)n;
    int count = 0;
    for (int i = 0; i < MAX_COUNTERS; i++) count += open_counters[i];
    return em_int(count);
}

static const EmEntry entries[] = {
    {"Selftest::_add", add},
    {"Selftest::_halve", halve},
    {"Selftest::_invert", invert},
    {"Selftest::_shout", shout},
    {"Selftest::_reverse_bytes", reverse_bytes},
    {"Selftest::_ping", ping},
    {"Selftest::_always_fails", always_fails},
    {"SelftestCounter::_open", counter_open},
    {"SelftestCounter::_next", counter_next},
    {"SelftestCounter::_close", counter_close},
    {"Selftest::_open_count", open_count},
};

static const EmModule module = {
    EMERALD_ABI_VERSION,
    "selftest",
    entries,
    sizeof entries / sizeof entries[0],
    NULL,
};

EM_EXPORT const EmModule *emerald_module(uint32_t host_abi_version) {
    return host_abi_version == EMERALD_ABI_VERSION ? &module : NULL;
}
