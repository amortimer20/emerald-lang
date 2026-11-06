/* The stub runtime's C interface, as generated C would include it. */
#ifndef EM_H
#define EM_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#if __STDC_HOSTED__
#include <math.h>
#else
#define sqrt __builtin_sqrt
#endif

typedef enum { EM_NOTHING, EM_INT, EM_FLOAT, EM_BOOL, EM_STRING, EM_LIST, EM_STRUCT, EM_DICT } EmTag;
typedef struct { uint8_t tag; uint64_t bits; } EmValue;
typedef struct { uint32_t count; uint8_t tag; } EmHeader;
typedef struct EmStr EmStr;
typedef struct EmList EmList;
typedef struct EmDict EmDict;
typedef struct { EmHeader header; size_t len; EmValue *fields; } EmStruct;

static inline EmValue em_int(int64_t v) { EmValue r; r.tag = EM_INT; r.bits = (uint64_t)v; return r; }
static inline EmValue em_float(double v) { EmValue r; r.tag = EM_FLOAT; __builtin_memcpy(&r.bits, &v, 8); return r; }
static inline EmValue em_obj(EmTag tag, void *p) { EmValue r; r.tag = tag; r.bits = (uint64_t)(uintptr_t)p; return r; }
static inline int64_t em_as_int(EmValue v) { return (int64_t)v.bits; }
static inline double em_as_float(EmValue v) { double d; __builtin_memcpy(&d, &v.bits, 8); return d; }
static inline void *em_as_ptr(EmValue v) { return (void *)(uintptr_t)v.bits; }

void em_retain(EmValue v);
void em_release(EmValue v);
int em_fail(const char *message, int line);
int em_fail_overflow(int line);
int em_report(void);

void em_flush(void);
void em_out_int(int64_t v);
void em_out_float(double v);
void em_out_str(EmStr *s);
void em_out_sep(void);
void em_out_newline(void);

double em_float_round_to(double v, int64_t places);

EmStr *em_str_new(const char *bytes, size_t len);
EmStr *em_list_join(EmList *list, EmStr *separator);
EmList *em_str_words(EmStr *s);

EmList *em_list_new(void);
EmList *em_list_unique(EmList **slot);
void em_list_append(EmList **slot, EmValue v);
int64_t em_list_count(EmList *l);
int em_list_get(EmList *l, int64_t index, EmValue *result, int line);
int em_list_struct_for_write(EmList **slot, int64_t index, EmStruct **result, int line);

EmStruct *em_struct_new(size_t len, const EmValue *fields);

EmDict *em_dict_new(void);
bool em_dict_get(EmDict *d, EmValue key, EmValue *result);
void em_dict_set(EmDict **slot, EmValue key, EmValue value);
int64_t em_dict_count(EmDict *d);
EmList *em_dict_entries(EmDict *d);

typedef int (*EmKeyFn)(void *env, EmValue item, EmValue *result);
int em_list_sort_by(EmList *l, EmKeyFn key, void *env, EmList **result);

int64_t em_random_next(int64_t *state, int64_t first, int64_t end);

#endif
