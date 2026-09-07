## Adversarial: definite assignment has to agree with control flow, not just with a
## straight line of statements. Every shape here reaches the end with the field assigned,
## by a different route through the constructor.
##
## The paired failures live in err_initialization_misses_a_branch, which takes the same
## shapes and removes one assignment from each.

class Branched {
    var n: Int
    constructor(flag: Bool) {
        if flag { self.n = 1 } else { self.n = 2 }
    }
}
print(Branched(true).n)
print(Branched(false).n)

## A guard clause: the early return carries its own assignment, so the statement after
## the if is only reached on the path that has not assigned yet.
class Guarded {
    var n: Int
    constructor(flag: Bool) {
        if flag {
            self.n = 1
            return
        }
        self.n = 2
    }
}
print(Guarded(true).n)
print(Guarded(false).n)

## Nested branches, where only the innermost arms assign.
class Nested {
    var n: Int
    constructor(a: Bool, b: Bool) {
        if a {
            if b { self.n = 1 } else { self.n = 2 }
        } else {
            self.n = 3
        }
    }
}
print(Nested(true, true).n)
print(Nested(true, false).n)
print(Nested(false, false).n)

## Both halves of a try assign, so every path out of it has.
class Tried {
    var n: Int
    constructor() {
        try { self.n = 1 } catch e { self.n = 2 }
    }
}
print(Tried().n)
