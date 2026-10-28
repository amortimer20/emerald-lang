# Mistake: enum value without its type (line 5). Source: carry-over from C enums.
enum Color {
    red, green
}
var c: Color = red
print(c)
