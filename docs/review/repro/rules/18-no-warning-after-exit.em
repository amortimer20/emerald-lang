# Section 14.1: "Unreachable executable statements after unconditional `return`,
# `raise`, loop exit, or `exit()` produce a warning". `check` reports no problems.
print("one")
exit(0)
print("two")

func stop() {
    exit(1)
    print("never")
}
