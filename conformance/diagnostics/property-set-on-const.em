struct Point {
    var x: Int
}

struct Box {
    var corner: Point
    var tags: [String]

    const size: Int {
        return self.corner.x * 2
    }

    var origin: Point {
        get {
            return self.corner
        }
        set {
            self.corner = value
        }
    }

    var labels: [String] {
        get {
            return self.tags
        }
        set {
            self.tags = value
        }
    }
}

const box = Box(Point(1), [])
print(box.size, box.origin)
box.origin = Point(2)
