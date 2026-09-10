## A module file runs top to bottom, vars and statements alike.
##
## §3.3 splits a file into members and an initializer, which puts its top-level vars in
## one list and its statements in another. Putting them back by line rather than
## appending one list to the other is the difference between this file and a file where
## every print happens after every assignment.
print("1. before the var")

var greeting = shout("2. the var's own initializer")

print("3. after the var, and it can see it: #{greeting}")

var second = shout("4. a later var")

print("5. last")

func shout(s: String): String { print(s)  return s.upper() }
