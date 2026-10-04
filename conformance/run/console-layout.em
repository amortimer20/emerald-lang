assert Console.panel("hi") == "┌────┐\n│ hi │\n└────┘"
assert Console.panel("one\ntwo\n") == "┌─────┐\n│ one │\n│ two │\n└─────┘"
assert Console.panel("hi", title: "Long") == "┌─ Long ┐\n│ hi    │\n└───────┘"
assert Console.panel(Console.panel("x")) == "┌───────┐\n│ ┌───┐ │\n│ │ x │ │\n│ └───┘ │\n└───────┘"

assert Console.table([["Ada", "120"], ["Grace", "95"]]) == "┌───────┬─────┐\n│ Ada   │ 120 │\n│ Grace │ 95  │\n└───────┴─────┘"
assert Console.table([["Ada", "120"]], header: ["name", "points"]) == "┌──────┬────────┐\n│ name │ points │\n├──────┼────────┤\n│ Ada  │ 120    │\n└──────┴────────┘"
assert Console.table([], header: ["name"]) == "┌──────┐\n│ name │\n├──────┤\n└──────┘"
assert Console.table([]) == ""
assert Console.table([["中", "😀"], ["a", "b"]]) == "┌────┬────┐\n│ 中 │ 😀 │\n│ a  │ b  │\n└────┴────┘"
assert Console.table([[Console.red("red")]]) == "┌─────┐\n│ red │\n└─────┘"

try {
    Console.table([["a", "b"], ["c"]])
}
catch error: RuntimeError {
    assert error.message == "row 2 has 1 cell, but row 1 has 2 cells"
}
try {
    Console.table([["a\nb"]])
}
catch error: RuntimeError {
    assert error.message == "row 1, column 1 contains a line break"
}
print("layout passed")
