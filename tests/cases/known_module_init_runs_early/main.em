## KNOWN HOLE. The output below is what Emerald does today, and the first line of it is
## wrong. Recorded so that fixing it shows as a changed golden.
##
## §3.3 says a module file's top-level code runs once, on first member access -- lowered
## to a CLR static constructor, whose whole point is that a file does not act merely by
## existing. module_init checks that, and passes.
##
## It stops holding as soon as one module's top-level code names another. Here second.em
## computes its value from First.value, and First initializes before the entry file runs
## a single statement -- so "first initializing" appears above "entry", which is exactly
## the startup-order behavior §3.3 chose first-access to avoid.
##
## It is specifically about top level. Move the same reference inside a function body and
## First initializes lazily and correctly, which is what module_sees_itself and the case
## beside it already cover. So the lowering is right and something in loading is reaching
## the initializer early.
##
## Why it matters for the backend rather than only for the interpreter: a CLR static
## constructor genuinely cannot be triggered this way, so an emitted program would run
## these in a different order than the interpreter does -- and the interpreter is the
## specification. The fix belongs on this side.
print("entry")
print(Second.value)
print(First.value)
