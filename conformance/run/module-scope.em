# Section 7.1: a function sees module variables declared above it, may update
# them, and may reuse a module-level name for a parameter (section 6.1).

const limit = 10

func clamp(score: Int): Int {
    if score > limit {
        return limit
    }
    return score
}

print(clamp(25), clamp(3))

var count = 0

func bump() {
    count += 1
}

bump()
bump()
print(count)

func twice(limit: Int): Int {
    return limit * 2
}

print(twice(4), limit)
