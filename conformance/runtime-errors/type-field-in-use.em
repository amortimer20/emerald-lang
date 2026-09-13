# Section 4.3's rule about a value being changed, for a type-level field: while
# a method changes it, nothing may reach it another way.
struct Point {
    var x: Int

    func shift() {
        self.x += 1
        print(Board.cursor)
    }
}

struct Board {
    var Board.cursor: Point = Point(0)
}

Board.cursor.shift()
