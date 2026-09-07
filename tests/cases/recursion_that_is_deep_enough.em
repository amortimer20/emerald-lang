## And the limit is not in the way. Nine thousand frames is deeper than any exercise a
## class will set, and the ceiling used to be about two thousand -- reachable by a
## recursive walk over a list of three thousand things, which is not an unusual program.
func depth(n: Int): Int {
    if n == 0 { return 0 }
    return 1 + depth(n - 1)
}

print(depth(9000))

## Recursion that branches, rather than a single chain, since that is what a tree walk
## looks like and it nests differently.
func leaves(n: Int): Int {
    if n == 0 { return 1 }
    return leaves(n - 1) + leaves(n - 1)
}

print(leaves(10))
