# Section 7.4's trailing block is the final argument, so it cannot also be
# given by name, and a call that leaves out a final function parameter is told
# it can be a block.
func each(block: func(Int)) {
    block(1)
}

each(block: { v => print(v) }) { v =>
    print(v)
}

func grid(width: Int, height: Int = 2, cell: func(Int, Int)) {
}

grid(1)

func nothing_to_fill() {
}

nothing_to_fill() { =>
    print(1)
}

struct Box {
    var label: String

    constructor(wide: Bool = self.label == "x") {
        self.label = "box"
    }
}
