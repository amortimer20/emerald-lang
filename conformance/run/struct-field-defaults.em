# Section 10.2: a field's default makes it optional in the generated
# constructor, and runs only when no argument replaced it.
struct Settings {
    var volume: Int = 5
    var name: String
    var loud: Bool = self.volume > 7
    var tags: [String] = []
}

print(Settings(name: "quiet"))
print(Settings(9, "loud"))
print(Settings(name: "forced", loud: true))

# Each construction runs the default again, so no two values share a list.
var first = Settings(name: "first")
first.tags.append("changed")
print(first.tags, Settings(name: "second").tags)

# A replaced default does not run at all.
var made = 0
func stamp(): Int {
    made += 1
    return made
}
struct Ticket {
    var number: Int = stamp()
    var row: Int = stamp()
}
print(Ticket(row: 12), Ticket(), made)

struct Ratio {
    var top: Float
    var bottom: Float = 1
}
print(Ratio(3))

# With a custom constructor, defaults run first, so those fields start out set
# and the constructor may build on them.
struct Counter {
    var count: Int = 10
    const step: Int = 2

    constructor(extra: Int) {
        self.count += extra * self.step
    }
}
print(Counter(1))
