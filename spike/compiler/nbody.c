/* Hand-lowered from benchmarks/nbody.em. Structs live on the shared heap as
 * erased values (decision 4: one runtime), so each field read goes through
 * the list and the struct, and each field write makes both unique first. */
#include "em.h"

enum { BODY_X, BODY_Y, BODY_VX, BODY_VY, BODY_MASS };

static EmValue body_new(double x, double y, double vx, double vy, double mass) {
    EmValue fields[5] = { em_float(x), em_float(y), em_float(vx), em_float(vy), em_float(mass) };
    return em_obj(EM_STRUCT, em_struct_new(5, fields));
}

static inline double field(EmValue body, int index) {
    return em_as_float(((EmStruct *)em_as_ptr(body))->fields[index]);
}

int main(void) {
    int status = 0;
#line 11 "nbody.em"
    EmList *bodies = em_list_new();
    em_list_append(&bodies, body_new(0.0, 0.0, 0.0, 0.0, 1000.0));
    em_list_append(&bodies, body_new(100.0, 0.0, 0.0, 3.0, 1.0));
    em_list_append(&bodies, body_new(-150.0, 0.0, 0.0, -2.5, 1.0));
    em_list_append(&bodies, body_new(0.0, 200.0, -2.2, 0.0, 1.0));
    em_list_append(&bodies, body_new(0.0, -250.0, 2.0, 0.0, 1.0));

#line 19 "nbody.em"
    for (int64_t step = 1; step <= 8000; step++) {
#line 20 "nbody.em"
        int64_t n1 = em_list_count(bodies);
        for (int64_t i = 0; i < n1; i++) {
            double ax = 0.0, ay = 0.0;
#line 23 "nbody.em"
            int64_t n2 = em_list_count(bodies);
            for (int64_t j = 0; j < n2; j++) {
                if (i == j) continue;
                EmValue bj, bi;
#line 27 "nbody.em"
                if ((status = em_list_get(bodies, j, &bj, 27))) goto fail;
                if ((status = em_list_get(bodies, i, &bi, 27))) goto fail;
                double dx = field(bj, BODY_X) - field(bi, BODY_X);
#line 28 "nbody.em"
                double dy = field(bj, BODY_Y) - field(bi, BODY_Y);
#line 29 "nbody.em"
                double distance = sqrt(dx * dx + dy * dy + 0.01);
#line 30 "nbody.em"
                double pull = field(bj, BODY_MASS) / (distance * distance * distance);
                ax += dx * pull;
                ay += dy * pull;
            }
            EmStruct *b;
#line 34 "nbody.em"
            if ((status = em_list_struct_for_write(&bodies, i, &b, 34))) goto fail;
            b->fields[BODY_VX] = em_float(em_as_float(b->fields[BODY_VX]) + ax * 0.01);
#line 35 "nbody.em"
            if ((status = em_list_struct_for_write(&bodies, i, &b, 35))) goto fail;
            b->fields[BODY_VY] = em_float(em_as_float(b->fields[BODY_VY]) + ay * 0.01);
        }
#line 37 "nbody.em"
        int64_t n3 = em_list_count(bodies);
        for (int64_t i = 0; i < n3; i++) {
            EmStruct *b;
#line 38 "nbody.em"
            if ((status = em_list_struct_for_write(&bodies, i, &b, 38))) goto fail;
            b->fields[BODY_X] = em_float(em_as_float(b->fields[BODY_X]) + em_as_float(b->fields[BODY_VX]) * 0.01);
#line 39 "nbody.em"
            if ((status = em_list_struct_for_write(&bodies, i, &b, 39))) goto fail;
            b->fields[BODY_Y] = em_float(em_as_float(b->fields[BODY_Y]) + em_as_float(b->fields[BODY_VY]) * 0.01);
        }
    }
    {
        EmValue b1;
#line 42 "nbody.em"
        if ((status = em_list_get(bodies, 1, &b1, 42))) goto fail;
        em_out_float(em_float_round_to(field(b1, BODY_X), 3));
        em_out_sep();
        em_out_float(em_float_round_to(field(b1, BODY_Y), 3));
        em_out_newline();
    }
    em_release(em_obj(EM_LIST, bodies));
    em_flush();
    return 0;
fail:
    em_release(em_obj(EM_LIST, bodies));
    return em_report();
}
