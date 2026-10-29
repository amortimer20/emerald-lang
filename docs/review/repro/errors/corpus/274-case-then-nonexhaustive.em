# Mistake: value case missing an arm (line 6). Source: guide docs/language/core.md.
enum Color {
    red, green, blue
}
var c = Color.red
var name = case c {
    when Color.red then "red"
    when Color.green then "green"
}
print(name)
