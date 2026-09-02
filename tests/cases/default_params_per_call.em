## A default is evaluated on every call that omits the argument, not once when the
## function is declared. Python evaluates once, which is why def f(x=[]) shares one
## list between calls — the trap this avoids.
var issued = 0

func next_id(): Int {
    issued += 1
    return issued
}

func label(text: String, id: Int = next_id()): String {
    return "##{id} #{text}"
}

print(label("first"))
print(label("second"))

## Supplying the argument does not evaluate the default at all.
print(label("given", 99))
print("issued: #{issued}")
