@deprecated("Use `total` instead.")
func sum_all(items: List[Int]): Int {
    return 0
}

@deprecated("Use `limit` instead.")
const max_items = 3

@deprecated("Use `Point` instead.")
struct Spot {
    @deprecated("Use `x` instead.")
    var left: Int
    var x: Int = 0

    @deprecated("Use `moved` instead.")
    func shifted(): Spot {
        return self
    }

    @deprecated("Use `area` instead.")
    const size: Int {
        return 1
    }

    @deprecated("Use `Spot.origin` instead.")
    func Spot.zero(): Spot {
        return Spot(0)
    }
}

enum Light {
    red
    @deprecated("Use `Light.yellow` instead.")
    amber
    yellow, green
}

print(sum_all([1]), max_items, Spot(1).shifted().size, Spot.zero(), Light.amber, Spot(2).left)
