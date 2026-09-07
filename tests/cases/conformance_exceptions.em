## A conformance vector for the CIL backend: which handler runs, and what does not.
##
## CLR exception handling is its own instruction set -- protected regions, leave, and a
## filter mechanism with no counterpart in the source language -- so this is the part of
## the emitter least able to borrow its shape from the interpreter. Every line below is
## an ordering the emitted regions have to reproduce.

class NotFound extends Error { }
class Deeper extends NotFound { }

## A throw abandons the rest of the block; the first clause whose type matches wins, and
## a subclass is matched by a clause naming its base.
func risky(n: Int) {
    print("before #{n}")
    throw Deeper("deep #{n}")
    print("NEVER: past the throw")
}

try {
    risky(1)
} catch e: NotFound {
    print("caught as NotFound: #{e.message}")
} catch e {
    print("NEVER: a later clause after one matched")
}

## Clause order decides, not specificity: the first match wins even when a later clause
## names the exact type. The checker warns about that arrangement rather than silently
## reordering it, and the warning is part of this file's expected output -- a backend
## that quietly picked the more specific clause would print the other line.
try {
    throw Deeper("ordering")
} catch e: NotFound {
    print("first clause won: #{e.message}")
} catch e: Deeper {
    print("NEVER: the exact type came second")
}

## A clause that does not match does not catch, and the error keeps travelling outward.
try {
    try { throw NotFound("inner") } catch e: Deeper { print("NEVER: wrong type") }
} catch e {
    print("outer caught: #{e.message}")
}

## A return inside a try leaves the function through the protected region.
func gives(): Int {
    try { return 1 } catch e { return 2 }
}
print(gives())

## throw with text builds an ordinary Error, so an untyped clause sees a message either
## way -- and a failed assert is catchable like anything else.
try { throw "plain text" } catch e { print("plain: #{e.message}") }
try { assert 1 == 2 } catch e { print("assert was catchable") }

## An error caught and rethrown reaches the outer handler, and the type survives.
try {
    try { throw Deeper("rethrown") } catch e: Deeper { throw e }
} catch e: NotFound {
    print("rethrow kept its type: #{e.message}")
}

print("done")
