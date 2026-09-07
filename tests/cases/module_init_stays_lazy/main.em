## A module's top-level code runs on first member access, and that holds when one module
## is reached only from inside another module's initializer.
##
## It did not before. A module's top-level `var` had been treated as a class's `static
## var` and evaluated when the type was declared, so second.em's `var value =
## First.value + 10` ran at startup and dragged First up with it -- "first initializing"
## appeared above "entry", which is exactly the act-by-existing that §3.3 chose
## first-access to avoid. The statements were deferred correctly; only the vars were not,
## so a file ran half at startup and half on access.
##
## A top-level `var` is top-level code. It now waits with the rest of the file, and the
## two halves are put back in the order they were written rather than one appended to the
## other -- a print above a var and a print below it are different programs.
print("entry")
print(Second.value)
print(First.value)
