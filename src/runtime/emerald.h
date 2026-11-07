/* The runtime's C interface, as a compiled Emerald program sees it
 * (src/runtime/compiled.zig). `emerald build` writes this beside the C it
 * generates; it is versioned with Emerald, and the runtime library a program
 * links must come from the same release. */
#ifndef EMERALD_H
#define EMERALD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Where a failure happened: `path:line:column`, then the quoted source line
 * and its carets, each ending in a newline. */
typedef struct {
    const char *location;
    const char *snippet;
} em_site;

/* One call on the way out of a failure: the function called, and where. */
typedef struct {
    const char *function;
    const char *location;
    bool named;
} em_frame;

/* Section 5.3's arithmetic operators, in the runtime's order. */
enum {
    EM_ADD,
    EM_SUBTRACT,
    EM_MULTIPLY,
    EM_DIVIDE,
    EM_FLOOR_DIVIDE,
    EM_REMAINDER,
    EM_POWER
};

/* Section 5.3's `//` and `%` for a divisor the caller has checked is not
 * zero: the quotient rounds toward negative infinity, and the remainder takes
 * the divisor's sign. Every value is divisible by -1, and `%` by it is zero,
 * which C's `%` leaves undefined for the minimum. */
static inline int64_t em_floor_divide(int64_t left, int64_t right) {
    int64_t quotient = left / right;
    if (left % right != 0 && ((left < 0) != (right < 0))) quotient -= 1;
    return quotient;
}

static inline int64_t em_remainder(int64_t left, int64_t right) {
    if (right == -1) return 0;
    int64_t remainder = left % right;
    if (remainder != 0 && ((remainder < 0) != (right < 0))) remainder += right;
    return remainder;
}

void em_start(void);
int em_finish(int status);
void em_trace(const em_frame *frame);

void em_write_text(const char *bytes, size_t len);
void em_write_int(int64_t value);
void em_write_float(double value);
void em_write_bool(bool value);

int em_int_arithmetic(int op, int64_t left, int64_t right, int64_t *result, const em_site *site);
int em_float_arithmetic(int op, double left, double right, double *result, const em_site *site);
int em_negate(int64_t value, int64_t *result, const em_site *site);
int em_compare_int_float(int64_t left, double right);

#endif
