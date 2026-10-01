# Equality callbacks may read the original list, but cannot write through it.
var items: List[Item] = []
var action = "read"
var calls = 0

func change_items() {
    case action {
        when "append" {
            for n in 0..<100 {
                items.append(Item(n))
            }
        }
        when "insert" { items.insert(0, Item(9)) }
        when "remove" { items.remove(Item(9)) }
        when "clear" { items.clear() }
        when "reverse" { items.reverse!() }
        when "index" { items[0] = Item(9) }
        when "replace" { items = [] }
        when "late" {
            if calls > 1 {
                items.append(Item(9))
            }
        }
        when "copy" {
            var copy = items
            copy.append(Item(9))
            assert(copy.count == 4)
        }
    }
}

class Item with Equatable {
    const id: Int

    @override
    func equals(other: Item): Bool {
        calls += 1
        assert(items.count == 3)
        assert(items[0].id == 2)
        assert(items[1].id == 1)
        assert(items[2].id == 2)
        change_items()
        return self.id == other.id
    }
}

func exercise(method: String) {
    case method {
        when "contains?" { assert(items.contains?(Item(1))) }
        when "unique" { assert(items.unique().count == 2) }
        when "remove" { items.remove(Item(1)) }
        when "remove_all" { items.remove_all(Item(2)) }
        when "unique!" { items.unique!() }
    }
}

for method in ["contains?", "unique", "remove", "remove_all", "unique!"] {
    for requested in ["read", "copy", "append", "insert", "remove", "clear", "reverse", "index", "replace"] {
        items = [Item(2), Item(1), Item(2)]
        action = requested
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
        assert(rejected == (requested != "read" and requested != "copy"))
        if rejected {
            assert(items.map { item => item.id } == [2, 1, 2])
        }
    }
}

# Errors after earlier matching decisions still leave the original intact.
for method in ["remove_all", "unique!"] {
    items = [Item(2), Item(1), Item(2)]
    action = "late"
    calls = 0
    var rejected = false
    try {
        exercise(method)
    }
    catch error: RuntimeError {
        assert(error.message == "a callback cannot change `items` while `#{method}` is using it")
        rejected = true
    }
    assert(rejected)
    assert(items.map { item => item.id } == [2, 1, 2])
}
print("equality callback reads, copies, and mutation guards passed")
