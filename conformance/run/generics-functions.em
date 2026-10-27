# Section 11.3: generic functions, their types worked out at each call from
# the arguments, from a block's result, or from where the result goes.
func first_or[Item](items: List[Item], fallback: Item): Item {
    return if items.empty?() then fallback else items[0]
}

func swap[First, Second](pair: (First, Second)): (Second, First) {
    return (pair.1, pair.0)
}

func repeated[Item](items: List[Item], times: Int): List[Item] {
    var result: List[Item] = []
    for item in items {
        for _ in 0..<times {
            result.append(item)
        }
    }
    return result
}

func apply_all[Item, Result](items: List[Item], change: func(Item): Result): List[Result] {
    var results: List[Result] = []
    for item in items {
        results.append(change(item))
    }
    return results
}

# Recursive, with its return type written.
func count_of[Item](items: List[Item]): Int {
    return if items.empty?() then 0 else 1 + count_of(items.drop(1))
}

print(first_or([3, 4], 0), first_or([], "none"))
print(swap(("a", 1)))
print(repeated(["x", "y"], 2))
print(apply_all([1, 2, 3]) { number => number * 1.5 })
print(apply_all(["pear", "fig"]) { word => word.count })
print(count_of(["a", "b", "c"]))

# A Float result makes whole numbers Floats, as a List[Float] does.
const rates: List[Float] = repeated([1, 2], 1)
print(rates)
const half: Float = first_or([], 2)
print(half)
print(first_or([1.5], 2))

# Taken as a value, a generic function needs a type that says its own.
func same[Item](value: Item): Item {
    return value
}

const whole: func(Int): Int = same
const real: func(Float): Float = same
print(whole(3), real(3), real(2.5))

# A nested generic function.
func sizes(): Int {
    func size[Item](items: List[Item]): Int {
        return items.count
    }
    return size([1, 2]) + size(["a"])
}

print(sizes())
