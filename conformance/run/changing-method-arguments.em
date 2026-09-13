# Sections 4.3 and 7.3: a changing method has its receiver to itself only once
# its arguments are evaluated, and its defaults are among them, so a default
# may read the variable the receiver lives in, and `self` as it is before the
# call.
struct Tally {
    var marks: [String]

    func mark(label: String = describe(), twice: Bool = self.marks.count > 1) {
        self.marks.append(label)
        if twice {
            self.marks.append(label)
        }
    }
}

var tallies = [Tally([]), Tally(["x"])]

func describe(): String {
    return "#{tallies.count}:#{tallies[1].marks.count}"
}

tallies[1].mark()
tallies[1].mark("b")
tallies[1].mark()
print(tallies)

# The receiver is a place, reached when the call begins, after its arguments:
# an argument that replaces the variable is seen by a changing method, as it is
# by `append` and by assignment. A method that only reads receives the value it
# had before its arguments, like any other operand read left to right.
struct Point {
    var x: Int

    func show(label: String) {
        print(label, self.x)
    }

    func shift(by: Int) {
        self.x += by
    }
}

var point = Point(1)

func replace(): Int {
    point = Point(100)
    return 1
}

point.show("#{replace()}")
point = Point(1)
point.shift(replace())
print(point)

var items = [1]

func reset(): Int {
    items = [7, 8]
    return 9
}

items.append(reset())
print(items)
