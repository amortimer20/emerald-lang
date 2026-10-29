# Mistake: new before a constructor (line 6). Source: carry-over from Java/C; carry-over from JavaScript.
struct Point {
    var x: Int
    var y: Int
}
var p = new Point(1, 2)
print(p)
