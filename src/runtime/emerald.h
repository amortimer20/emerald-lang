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
enum { EM_KIND_NOTHING, EM_KIND_BOOL, EM_KIND_INT, EM_KIND_FLOAT, EM_KIND_STRING, EM_KIND_BYTES, EM_KIND_RANGE, EM_KIND_LIST, EM_KIND_TUPLE, EM_KIND_MAP, EM_KIND_CLOSURE, EM_KIND_STRUCT };
typedef struct em_struct em_struct;
typedef struct em_struct_type em_struct_type;
typedef struct em_list em_list;
typedef struct em_tuple em_tuple;
typedef struct em_map em_map;
typedef struct {
    uint8_t kind;
    union {
        int64_t integer;
        double number;
        bool boolean;
        em_text *text;
        em_list *list;
        em_tuple *tuple;
        em_map *map;
        em_struct *structure;
    } as;
} em_value;

int em_native(int family, int method, em_value receiver, const em_value *arguments, size_t count, uint8_t expected, em_value *result, const em_site *site);

/* Lists, held as strings are. A change goes through the slot holding the
 * list, which the runtime makes its only holder first. */
void em_retain_list(em_list *list);
void em_release_list(em_list *list);
em_list *em_list_new(uint8_t element, const em_value *items, size_t count);
int64_t em_list_count(em_list *list);
int em_list_get(em_list *list, int64_t position, em_value *result, const em_site *site);
int em_list_set(em_list **slot, int64_t position, em_value value, const em_site *site);
int em_list_mutate(em_list **slot, int method, const em_value *arguments, size_t count, uint8_t expected, em_value *result, const em_site *site);
void em_write_value(em_value value);
void em_builder_value(em_builder *builder, em_value value);
bool em_equal_values(em_value left, em_value right);

/* Optionals and tuples. An optional is an `em_value` whose kind is
 * EM_KIND_NOTHING when it is absent; a zeroed one is absent. */
void em_retain_value(em_value value);
void em_release_value(em_value value);
void em_retain_tuple(em_tuple *tuple);
void em_release_tuple(em_tuple *tuple);
em_tuple *em_tuple_new(const em_value *items, size_t count);
em_value em_tuple_get(em_tuple *tuple, size_t position);

/* Dictionaries and sets, held as lists are. */
void em_retain_map(em_map *map);
void em_release_map(em_map *map);
em_map *em_map_new(uint8_t key_kind, uint8_t value_kind, bool is_set);
int em_map_put(em_map *map, em_value key, em_value value, const em_site *site);
int em_map_set(em_map **slot, em_value key, em_value value, const em_site *site);
int em_map_get(em_map *map, em_value key, em_value *result, const em_site *site);
int em_map_get_existing(em_map *map, em_value key, em_value *result, const em_site *site);
int64_t em_map_count(em_map *map);
int em_map_change(em_map **slot, int method, const em_value *arguments, size_t count, uint8_t expected, em_value *result, const em_site *site);
em_list *em_map_items(em_map *map);
em_list *em_string_characters(em_text *text);

/* Structs: values described by a type the program builds once. A change
 * goes through the slot holding the struct, which the runtime makes its only
 * holder first. */
void em_retain_struct(em_struct *instance);
void em_release_struct(em_struct *instance);
em_struct_type *em_struct_descriptor(em_struct_type **cell, const char *name, const char *display_name, const char *const *names, const uint8_t *kinds, size_t count);
em_struct *em_struct_new(const em_struct_type *type, const em_value *values, size_t count);
em_value em_struct_get(em_struct *instance, size_t position);
void em_struct_set(em_struct **slot, size_t position, em_value value);

#endif
