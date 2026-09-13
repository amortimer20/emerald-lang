using Shapes

struct Other {
    var count: Int

    func steal(counter: Counter): Int {
        return counter._count
    }
}

var counter = Counter()
print(counter._count)
Counter._reset()
print(Shapes.Counter._made)
print(Counter(_count: 3))
