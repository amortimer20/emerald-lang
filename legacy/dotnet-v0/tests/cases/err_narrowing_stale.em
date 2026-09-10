## Narrowing proves what a variable holds at the moment of the check. A call in between
## can undo it, and the checker went on believing the proof — so this compiled and then
## crashed with the exact null-reference failure non-nullable types exist to abolish.
var name: String? = "ada"

func clear() {
    name = nothing
}

if name != nothing {
    clear()
    print(name.count)
}
