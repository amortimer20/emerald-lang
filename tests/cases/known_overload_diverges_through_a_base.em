## KNOWN HOLE. The output below is what the interpreter does, and a compiled backend
## would print something else. Recorded so the fix shows as a changed golden.
##
## The invariant this violates, stated so it can be tested rather than assumed:
##
##     Every call the checker accepts selects the same declaration the interpreter
##     invokes.
##
## Sub.go(Dog) is not an override of Base.go(Animal) -- different parameter type, so it
## is a new overload, and since overloads inherit, a Sub has both. Through a Sub the two
## rules agree on Sub.go(Dog). Through a Base they do not: Base declares only go(Animal),
## so static resolution binds there, while the interpreter looks at the runtime object,
## finds Sub's more specific version, and calls that.
##
## This is the direct consequence of dropping the overload hiding rule. That was still
## the right call -- the rule could not survive the CLR boundary either way -- but it
## made the interpreter's runtime selection observable, which it had not been before.
##
## The fix is not to ban the declaration: C# and Java both allow it, and rejecting it
## would put the hiding rule back under another name. It is to make one decision instead
## of two -- the checker already resolves this call, so it should record which
## declaration it chose and the interpreter should invoke that one, rather than both
## reconstructing the answer from different information.

class Animal { }
class Dog extends Animal { }

class Base {
    func go(a: Animal): String { return "base Animal" }
}

class Sub extends Base {
    func go(d: Dog): String { return "sub Dog" }
}

var s = Sub()
var b: Base = s

## Both rules agree here.
print(s.go(Dog()))

## And disagree here. A backend prints "base Animal".
print(b.go(Dog()))
