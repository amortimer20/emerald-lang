## A function that gives back a value has to say what kind. Without this the missing
## annotation resolved to the checker's permissive unknown, and `var word: String =
## answer()` bound an Int to a String with nothing said -- not a conversion and not a
## String holding digits, but a variable holding a genuine Int while the checker
## believed otherwise. The failure then surfaced inside whatever correct, fully
## annotated function the value reached.
func answer() {
    return 42
}

var word: String = answer()
print(word.upper())
