/* The Godot question: generated C built as a shared library whose exported C
 * functions a host loads, the way Godot loads a GDExtension through its entry
 * function. A real binding would export `godot_entry` and register classes;
 * this exports a compiled Emerald function and a status-checked call. */
#include "em.h"

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

static int em_fn_fib(int64_t n, int64_t *result) {
    if (n < 2) { *result = n; return 0; }
    int64_t a, b, t;
    if (__builtin_sub_overflow(n, 1, &t)) return em_fail_overflow(7);
    if (em_fn_fib(t, &a)) return 1;
    if (__builtin_sub_overflow(n, 2, &t)) return em_fail_overflow(7);
    if (em_fn_fib(t, &b)) return 1;
    if (__builtin_add_overflow(a, b, result)) return em_fail_overflow(7);
    return 0;
}

/* Returns 0 and writes the result, or a nonzero status after an Emerald
 * runtime error, which the host would turn into its own error. */
EXPORT int emerald_fib(int64_t n, int64_t *result) {
    return em_fn_fib(n, result);
}

/* The entry a host calls first, standing in for GDExtension's `godot_entry`. */
EXPORT int emerald_entry(uint32_t host_version) {
    return host_version == 1 ? 1 : 0;
}
