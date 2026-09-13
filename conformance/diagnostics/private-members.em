struct Counter {
    var _count: Int = 0
    var step: Int
    var Counter._made = 0

    func _bump(by: Int) {
        self._count += by
    }

    func Counter._make(): Counter {
        return Counter(0, 1)
    }
}

struct Secret {
    const _key: String
}

var c = Counter(0, 2)
print(c._count)
c._count = 3
c._count += 1
c._bump(1)
print(Counter._made)
Counter._made = 4
print(Counter._make())
const f = Counter._make
var s = Secret("x")
print(c._made)
