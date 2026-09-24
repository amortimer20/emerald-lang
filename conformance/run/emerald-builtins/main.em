# Every built-in is reachable in the `Emerald` namespace, even when a project
# name hides it: the program's own name wins bare (with a warning), and the
# qualified form reaches the built-in.
func print(text: String) {
    Emerald.print("> #{text}")
}

print("the program's own print")
Emerald.print("the built-in print", 2)
Emerald.write("no newline")
Emerald.print("")

Emerald.print(Math.half(10))
Emerald.print(Emerald.Math.pi > 3)
Emerald.print(Emerald.Program.arguments.count)
Emerald.print(Emerald.random(4..4))
