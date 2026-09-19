# Enough blocks, lists, and strings to make the collector run several times
# during the program rather than only at the end. What it prints is ordinary;
# the point is that the answers are the same whenever collection happens.

func counter_from(start: Int): func(): Int {
    var next = start
    return { =>
        next += 1
        return next - 1
    }
}

var counters: List[func(): Int] = []
for i in 1..500 {
    # The block is stored in the scope it captured, so each iteration leaves a
    # cycle behind that only the collector can reclaim.
    const block = { => i * 2 }
    counters.append(block)
}
print(counters.count)
print(counters[0]())
print(counters[499]())

var labels: List[String] = []
for i in 1..2000 {
    labels.append("row #{i}")
}
print(labels[1999])

const ticket = counter_from(1)
var drawn = 0
for _ in 1..1000 {
    drawn = ticket()
}
print(drawn)

# The counter still works after everything around it has been collected.
print(ticket())
print(labels.map { label => label.count }[0])
