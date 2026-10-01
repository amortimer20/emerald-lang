var items: List[Rank] = []
var changing = false
var calls = 0

struct Rank with Ordered {
    const value: Int

    @override
    func compare(other: Self): Int {
        calls += 1
        assert(items.count == 4)
        assert(items.map { item => item.value } == [4, 3, 1, 2])
        if changing and calls > 1 {
            items.sort!()
        }
        return self.value - other.value
    }
}

func exercise(method: String) {
    case method {
        when "sort" { assert(items.sort().map { item => item.value } == [1, 2, 3, 4]) }
        when "sort!" { items.sort!() }
        when "min" { assert(items.min()?.value == 1) }
        when "max" { assert(items.max()?.value == 4) }
        when "min_max" {
            const (minimum, maximum) = items.min_max()
            assert(minimum?.value == 1 and maximum?.value == 4)
        }
        when "sort_by" { assert(items.sort_by { item => item }.count == 4) }
        when "min_by" { assert(items.min_by { item => item }?.value == 1) }
        when "max_by" { assert(items.max_by { item => item }?.value == 4) }
    }
}

for method in ["sort", "sort!", "min", "max", "min_max", "sort_by", "min_by", "max_by"] {
    for requested in [false, true] {
        items = [Rank(4), Rank(3), Rank(1), Rank(2)]
        changing = requested
        calls = 0
        var rejected = false
        try {
            exercise(method)
        }
        catch error: RuntimeError {
            assert(error.message == "a callback cannot change `items` while `#{method}` is using it")
            rejected = true
        }
        assert(calls > 0)
        assert(rejected == requested)
        if rejected or method != "sort!" {
            assert(items.map { item => item.value } == [4, 3, 1, 2])
        }
    }
}
print("ordering callbacks see the original and reject mutation")
