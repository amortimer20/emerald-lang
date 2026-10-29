# No section says what running out of memory does. The interpreter ends the
# process with "emerald: ran out of memory" and status 70; the catch never runs,
# and the size computation's overflow is not reported as Int overflow.
try {
    print("ab".repeat(9223372036854775807).count)
}
catch error {
    print("caught", error.type_name, error.message)
}
