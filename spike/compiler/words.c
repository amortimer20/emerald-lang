/* Hand-lowered from benchmarks/words.em: strings, lists, a dictionary, a
 * seeded Random, and a closure passed to the runtime's sort. */
#include "em.h"

/* The block `{ entry => -entry.1 }`, which captures nothing. */
static int em_block_1(void *env, EmValue entry, EmValue *result) {
    (void)env;
#line 20 "words.em"
    int64_t count = em_as_int(((EmStruct *)em_as_ptr(entry))->fields[1]);
    int64_t negated;
    if (__builtin_sub_overflow((int64_t)0, count, &negated)) return em_fail_overflow(20);
    *result = em_int(negated);
    return 0;
}

int main(void) {
    int status = 0;
    static const char *const words[] = { "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "and", "runs" };
#line 3 "words.em"
    EmList *vocabulary = em_list_new();
    for (int k = 0; k < 10; k++) {
        const char *w = words[k];
        em_list_append(&vocabulary, em_obj(EM_STRING, em_str_new(w, __builtin_strlen(w))));
    }
#line 4 "words.em"
    int64_t generator_state = 11;
#line 5 "words.em"
    EmList *lines = em_list_new();
    EmStr *space = em_str_new(" ", 1);
    EmStr *newline = em_str_new("\n", 1);
#line 6 "words.em"
    for (int64_t a = 0; a < 20000; a++) {
#line 7 "words.em"
        EmList *line = em_list_new();
#line 8 "words.em"
        for (int64_t b = 0; b < 12; b++) {
            EmValue word;
#line 9 "words.em"
            int64_t index = em_random_next(&generator_state, 0, em_list_count(vocabulary));
            if ((status = em_list_get(vocabulary, index, &word, 9))) { em_release(em_obj(EM_LIST, line)); goto fail; }
            em_retain(word);
            em_list_append(&line, word);
        }
#line 11 "words.em"
        em_list_append(&lines, em_obj(EM_STRING, em_list_join(line, space)));
        em_release(em_obj(EM_LIST, line));
    }
#line 13 "words.em"
    EmStr *text = em_list_join(lines, newline);

#line 15 "words.em"
    EmDict *counts = em_dict_new();
#line 16 "words.em"
    EmList *all = em_str_words(text);
    for (int64_t k = 0; k < em_list_count(all); k++) {
        EmValue word, found;
        em_list_get(all, k, &word, 16);
#line 17 "words.em"
        int64_t current = em_dict_get(counts, word, &found) ? em_as_int(found) : 0;
        int64_t next;
        if (__builtin_add_overflow(current, 1, &next)) { status = em_fail_overflow(17); goto fail2; }
        em_retain(word);
        em_dict_set(&counts, word, em_int(next));
    }
#line 19 "words.em"
    {
        EmList *entries = em_dict_entries(counts);
        EmList *top;
        status = em_list_sort_by(entries, em_block_1, NULL, &top);
        em_release(em_obj(EM_LIST, entries));
        if (status) goto fail2;
        EmValue first;
#line 20 "words.em"
        if ((status = em_list_get(top, 0, &first, 20))) { em_release(em_obj(EM_LIST, top)); goto fail2; }
        EmStruct *pair = (EmStruct *)em_as_ptr(first);
        em_out_str((EmStr *)em_as_ptr(pair->fields[0]));
        em_out_sep();
        em_out_int(em_as_int(pair->fields[1]));
        em_out_sep();
        em_out_int(em_dict_count(counts));
        em_out_newline();
        em_release(em_obj(EM_LIST, top));
    }
    em_release(em_obj(EM_LIST, all));
    em_release(em_obj(EM_DICT, counts));
    em_release(em_obj(EM_STRING, text));
    em_release(em_obj(EM_LIST, lines));
    em_release(em_obj(EM_LIST, vocabulary));
    em_release(em_obj(EM_STRING, space));
    em_release(em_obj(EM_STRING, newline));
    em_flush();
    return 0;
fail2:
    em_release(em_obj(EM_LIST, all));
    em_release(em_obj(EM_DICT, counts));
    em_release(em_obj(EM_STRING, text));
fail:
    em_release(em_obj(EM_LIST, lines));
    em_release(em_obj(EM_LIST, vocabulary));
    return em_report();
}
