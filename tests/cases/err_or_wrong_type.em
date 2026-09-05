## .or gives back the type the ? was hiding, whichever way it goes — so a fallback of
## another type made the checker claim Int for an expression that produced a String.
var n: Int? = nothing

print(n.or("not a number"))
