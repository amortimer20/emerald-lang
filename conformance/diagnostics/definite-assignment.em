# Section 4.1 proves definite assignment through control flow rather than
# inserting a default value. Only the `then` branch assigns, so the path that
# skips it leaves the name unset, and the read below is rejected.
#
# This is also the canonical diagnostic printed in section 17.1.

var score: Int

if 1 > 0 {
    score = 1
}

print(score)
