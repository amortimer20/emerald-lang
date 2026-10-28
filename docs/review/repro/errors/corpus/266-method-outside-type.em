# Mistake: method body outside its struct (line 6). Source: carry-over from Python.
struct Point {
    var x: Int
}
func area(): Int {
    return self.x
}
