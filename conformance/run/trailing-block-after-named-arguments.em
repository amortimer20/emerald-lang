# Section 7.4: a trailing block occupies the final argument position, so it
# fills the last parameter whatever was named or left to a default inside the
# parentheses. A final function parameter may therefore follow defaulted ones.
func grid(width: Int, height: Int = 2, gap: Int = 0, cell: func(Int, Int)) {
    var y = 0
    while y < height {
        var x = 0
        while x < width {
            cell(x, y + gap)
            x += 1
        }
        y += 1
    }
}

grid(2, height: 1) { x, y =>
    print("a", x, y)
}
grid(1, gap: 5) { x, y =>
    print("b", x, y)
}
grid(width: 1, height: 1, cell: { x, y => print("c", x, y) })

func repeat(times: Int, block: func(Int)) {
    var i = 0
    while i < times {
        block(i)
        i += 1
    }
}

repeat(times: 2) { i =>
    print("repeat", i)
}

# A constructor's parameter defaults may read `self`, as a method's may, once
# the field they read is set: a field default runs first.
struct Box {
    var size: Int = 3
    var label: String

    constructor(label: String, wide: Bool = self.size > 2) {
        self.label = "#{label}:#{wide}"
    }
}

print(Box("a"), Box("b", wide: false))
