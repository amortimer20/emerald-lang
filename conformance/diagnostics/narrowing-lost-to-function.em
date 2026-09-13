# Section 4.5: a module variable a function assigns cannot be proved present,
# because calling that function between the test and the use is all it takes
# to set it back to `nothing`. A `const` copy can be proved present.
var name: String? = "Ada"

func forget() {
    name = nothing
}

if name != nothing {
    forget()
    print(name.count)
}

while name != nothing {
    print(name.count)
}

const kept = name
if kept != nothing {
    forget()
    print(kept.count)
}
