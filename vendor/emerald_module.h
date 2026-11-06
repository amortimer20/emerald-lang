/* The C interface between Emerald and a vendor library's native module
 * (docs/vendor-libraries-design-plan.md, decision 3).
 *
 * A module is a shared library that exports one function, `emerald_module`.
 * It returns a table of natives. Each native takes and returns plain values:
 * nothing, a boolean, an integer, a float, text, or bytes. Anything richer (a
 * window, an image, a sound) stays inside the module and crosses as an integer
 * handle that the module owns. No callbacks, pointers, or lists cross.
 *
 * Memory: text, bytes, and error messages that a native returns belong to the
 * module and must stay valid until the next call into the module. Emerald
 * copies them at once. Arguments belong to Emerald and are valid only for the
 * duration of the call. A module must never call back into Emerald.
 *
 * Threads: Emerald calls a module from one thread at a time.
 */
#ifndef EMERALD_MODULE_H
#define EMERALD_MODULE_H

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define EM_EXPORT __declspec(dllexport)
#else
#define EM_EXPORT __attribute__((visibility("default")))
#endif

#define EMERALD_ABI_VERSION 1u

enum {
    EM_NOTHING = 0,
    EM_BOOL = 1,
    EM_INT = 2,
    EM_FLOAT = 3,
    EM_TEXT = 4,  /* UTF-8, not zero-terminated */
    EM_BYTES = 5,
    EM_ERROR = 6, /* a native's failure: `as.bytes` is the message, UTF-8 */
};

typedef struct EmValue {
    uint32_t kind;
    union {
        uint8_t boolean;
        int64_t integer;
        double number;
        struct {
            const uint8_t *data;
            size_t length;
        } bytes;
    } as;
} EmValue;

/* `arguments` has `count` values, the declared parameters in order. */
typedef EmValue (*EmNative)(const EmValue *arguments, size_t count);

typedef struct EmEntry {
    /* The native's key without the namespace: `Selftest::_add` for the
     * declaration `func Selftest._add(...)` in the library's `.em` file. */
    const char *name;
    EmNative function;
} EmEntry;

typedef struct EmModule {
    uint32_t abi_version; /* EMERALD_ABI_VERSION */
    const char *library;  /* the library's name, as in `vendor.zon` */
    const EmEntry *entries;
    size_t entry_count;
    /* Called once when the program ends, if the module was loaded. May be NULL. */
    void (*shutdown)(void);
} EmModule;

/* The module's only exported symbol. Returns NULL if the module cannot work
 * with `host_abi_version`. */
EM_EXPORT const EmModule *emerald_module(uint32_t host_abi_version);

/* Helpers every module wants. */
static inline EmValue em_nothing(void) {
    EmValue value = {EM_NOTHING, {0}};
    return value;
}
static inline EmValue em_bool(int flag) {
    EmValue value;
    value.kind = EM_BOOL;
    value.as.boolean = flag ? 1 : 0;
    return value;
}
static inline EmValue em_int(int64_t integer) {
    EmValue value;
    value.kind = EM_INT;
    value.as.integer = integer;
    return value;
}
static inline EmValue em_float(double number) {
    EmValue value;
    value.kind = EM_FLOAT;
    value.as.number = number;
    return value;
}
static inline EmValue em_text(const char *data, size_t length) {
    EmValue value;
    value.kind = EM_TEXT;
    value.as.bytes.data = (const uint8_t *)data;
    value.as.bytes.length = length;
    return value;
}
static inline EmValue em_bytes(const uint8_t *data, size_t length) {
    EmValue value;
    value.kind = EM_BYTES;
    value.as.bytes.data = data;
    value.as.bytes.length = length;
    return value;
}
static inline EmValue em_error(const char *message, size_t length) {
    EmValue value;
    value.kind = EM_ERROR;
    value.as.bytes.data = (const uint8_t *)message;
    value.as.bytes.length = length;
    return value;
}

#endif
