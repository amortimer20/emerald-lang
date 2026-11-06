/* Hand-lowered from benchmarks/fib.em, as the C emitter would write it:
 * unboxed Int, checked arithmetic, a status return for every call that can
 * raise, and #line directives back to the Emerald source. */
#include "em.h"

static int em_fn_fib(int64_t n, int64_t *result) {
#line 4 "fib.em"
    if (n < 2) {
#line 5 "fib.em"
        *result = n;
        return 0;
    }
#line 7 "fib.em"
    int64_t t1, t2, t3, t4, t5;
    if (__builtin_sub_overflow(n, 1, &t1)) return em_fail_overflow(7);
    if (em_fn_fib(t1, &t2)) return 1;
    if (__builtin_sub_overflow(n, 2, &t3)) return em_fail_overflow(7);
    if (em_fn_fib(t3, &t4)) return 1;
    if (__builtin_add_overflow(t2, t4, &t5)) return em_fail_overflow(7);
    *result = t5;
    return 0;
}

int main(void) {
    int64_t t1;
#line 10 "fib.em"
    if (em_fn_fib(27, &t1)) return em_report();
    em_out_int(t1);
    em_out_newline();
    em_flush();
    return 0;
}
