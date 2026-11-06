/* Native glue for the library: one C function per native, each checking its
 * arguments and turning every failure into an error value whose first line is
 * the message and whose later lines say what to try (vendor/emerald_module.h).
 * Replace `example` and `Example` throughout; see docs/vendor-libraries.md. */
#include <string.h>

#include "../emerald_module.h"

static EmValue add(const EmValue *arguments, size_t count) {
    (void)count;
    return em_int(arguments[0].as.integer + arguments[1].as.integer);
}

static const EmEntry entries[] = {
    /* The name is `Type::member`, as the declaration `func Example._add` in
     * example.em gives it. */
    {"Example::_add", add},
};

static const EmModule module = {
    EMERALD_ABI_VERSION,
    "example",
    entries,
    sizeof entries / sizeof entries[0],
    NULL, /* a shutdown function, if the library needs one */
};

EM_EXPORT const EmModule *emerald_module(uint32_t host_abi_version) {
    return host_abi_version == EMERALD_ABI_VERSION ? &module : NULL;
}
