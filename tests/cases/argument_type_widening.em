## Int widens into Float, and T into T? — neither is an error.
func area(w: Float, h: Float): Float { return w * h }
func label(text: String?): String { return text.or("none") }

print(area(3, 4))
print(label("hi"))
