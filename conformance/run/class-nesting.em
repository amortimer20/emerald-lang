# Objects inside structs, structs and lists inside objects, and objects that
# refer to each other. A change that reaches an object changes it where it is.

struct Point {
    var x: Int
    var y: Int

    func shift(by: Int) {
        self.x += by
    }

    var sum: Int {
        get {
            return self.x + self.y
        }
        set {
            self.x = value - self.y
        }
    }
}

class Node {
    var name: String
    var at: Point = Point(0, 0)
    var next: Node? = nothing
    var points: [Point] = []

    func link_back() {
        func inner() {
            self.next = self
        }
        inner()
    }
}

struct Holder {
    var node: Node
    const label: String = "h"
}

const n = Node("n")
n.at.x = 5
n.at.shift(2)
n.at.sum = 10
n.points.append(Point(1, 1))
n.points[0].shift(4)
print(n.at, n.points)

const h = Holder(n)
h.node.name = "via holder"
const h2 = h
h2.node.at.y = 9
print(n.name, n.at)

n.link_back()
print(n)
const loop = Node("a")
const second = Node("b")
loop.next = second
second.next = loop
print(loop)

class Log {
    var lines: [String] = []
}
struct Logger {
    const log: Log

    func write(line: String) {
        self.log.lines.append(line)
    }

    func rename(line: String) {
        self.log.lines = [line]
    }
}
const shared_logger = Logger(Log())
shared_logger.write("one")
shared_logger.rename("two")
print(shared_logger.log.lines)

# A setter on an object, or on a struct inside one, can reach the object while
# it runs: nothing is taken out, since the object is shared.
class Panel {
    var size: Size = Size(1)
    var label: String = ""

    var caption: String {
        get {
            return self.label
        }
        set {
            self.label = value
            report()
        }
    }
}

struct Size {
    var width: Int

    var doubled: Int {
        get {
            return self.width * 2
        }
        set {
            self.width = value // 2
            report()
        }
    }
}

const panel = Panel()
func report() {
    print("panel is", panel.label, panel.size.width)
}
panel.caption = "hello"
panel.size.doubled = 10
