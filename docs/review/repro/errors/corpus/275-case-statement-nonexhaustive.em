# Mistake: statement case missing an enum arm (line 6). Source: guide docs/language/core.md; rewrite-context 17.1.
enum Color {
    red, green, blue
}
var c = Color.blue
case c {
    when Color.red {
        print("red")
    }
    when Color.green {
        print("green")
    }
}
