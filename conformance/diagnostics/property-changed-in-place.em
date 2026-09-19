struct Point {
    var x: Int
}

struct Box {
    var corner: Point
    var tags: List[String]

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

    var labels: List[String] {
        get {
            return self.tags
        }
        set {
            self.tags = value
        }
    }
}

var box = Box(Point(1), [])
box.origin.x = 5
box.labels.append("a")
box.labels[0] = "b"
