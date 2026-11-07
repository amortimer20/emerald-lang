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

/* Strings: `em_text` is the runtime's own string. Every slot that holds one
 * owns a reference; a function given one only borrows it, and one a function
 * gives back is the caller's. */
typedef struct em_text em_text;
typedef struct em_builder em_builder;

void em_retain(em_text *text);
void em_release(em_text *text);
em_text *em_literal(em_text **cell, const char *bytes, size_t len);
void em_write_string(em_text *text);
em_text *em_concat(em_text *left, em_text *right);
int em_compare_strings(em_text *left, em_text *right);
bool em_equal_strings(em_text *left, em_text *right);
int64_t em_string_count(em_text *text);
int em_string_index(em_text *text, int64_t position, em_text **result, const em_site *site);
int em_string_slice(em_text *text, bool has_start, int64_t start, bool has_end, int64_t end, bool inclusive, em_text **result, const em_site *site);

em_builder *em_builder_new(void);
void em_builder_text(em_builder *builder, const char *bytes, size_t len);
void em_builder_string(em_builder *builder, em_text *text);
void em_builder_int(em_builder *builder, int64_t value);
void em_builder_float(em_builder *builder, double value);
void em_builder_bool(em_builder *builder, bool value);
em_text *em_builder_finish(em_builder *builder);

/* A value crossing to a native, tagged in the runtime's `Value.Kind` order. */
enum { EM_KIND_NOTHING, EM_KIND_BOOL, EM_KIND_INT, EM_KIND_FLOAT, EM_KIND_STRING };
typedef struct {
    uint8_t kind;
    union {
        int64_t integer;
        double number;
        bool boolean;
        em_text *text;
    } as;
} em_value;

int em_native(int family, int method, em_value receiver, const em_value *arguments, size_t count, em_value *result, const em_site *site);

#endif
