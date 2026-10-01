class Box {
    var items: List[Int] = [3, 1, 2]

    func change() {
        self.items.append(9)
    }
}

const box = Box()
const alias = box
var rejected = false
try {
    box.items.remove_if { item =>
        assert(alias.items == [3, 1, 2])
        var copy = alias.items
        copy.append(4)
        assert(copy == [3, 1, 2, 4])
        if item == 1 {
            alias.items[0] = 9
        }
        return item == 3
    }
}
catch error: RuntimeError {
    assert(error.message == "a callback cannot change `items` while `remove_if` is using it")
    rejected = true
}
assert(rejected)
assert(box.items == [3, 1, 2])
box.items.remove_if { item =>
    assert(alias.items == [3, 1, 2])
    return item == 1
}
assert(box.items == [3, 2])

func mutate(method: String) {
    case method {
        when "append" { alias.items.append(9) }
        when "insert" { alias.items.insert(0, 9) }
        when "remove" { alias.items.remove(3) }
        when "remove_all" { alias.items.remove_all(3) }
        when "remove_if" { alias.items.remove_if { item => item == 3 } }
        when "remove_at" { alias.items.remove_at(0) }
        when "remove_first" { alias.items.remove_first() }
        when "remove_last" { alias.items.remove_last() }
        when "clear" { alias.items.clear() }
        when "reverse!" { alias.items.reverse!() }
        when "unique!" { alias.items.unique!() }
        when "sort!" { alias.items.sort!() }
        when "shuffle!" { alias.items.shuffle!() }
        when "random" { Random(1).shuffle!(alias.items) }
        when "index" { alias.items[0] += 1 }
        when "replace" { alias.items = [] }
        when "method" { alias.change() }
    }
}

for method in ["append", "insert", "remove", "remove_all", "remove_if", "remove_at", "remove_first", "remove_last", "clear", "reverse!", "unique!", "sort!", "shuffle!", "random", "index", "replace", "method"] {
    rejected = false
    try {
        box.items.remove_if { item =>
            assert(box.items == [3, 2])
            mutate(method)
            return false
        }
    }
    catch error: RuntimeError {
        assert(error.message == "a callback cannot change `items` while `remove_if` is using it")
        rejected = true
    }
    assert(rejected)
    assert(box.items == [3, 2])
}

# The same shared class field reached through a dictionary is still protected.
var boxes: Dict[String, Box] = ["one": box]
rejected = false
try {
    boxes["one"].or(Box()).items.remove_if { item =>
        assert(alias.items == [3, 2])
        alias.items.append(9)
        return false
    }
}
catch error: RuntimeError {
    assert(error.message == "a callback cannot change `items` while `remove_if` is using it")
    rejected = true
}
assert(rejected)
assert(box.items == [3, 2])

# A local binding and its value alias are distinct storage places.
func check_local() {
    var local = [3, 1, 2]
    var copy = local
    var rejected = false
    try {
        local.remove_if { item =>
            assert(local == [3, 1, 2])
            copy.append(9)
            if item == 1 {
                local.append(9)
            }
            return item == 3
        }
    }
    catch error: RuntimeError {
        assert(error.message == "a callback cannot change `local` while `remove_if` is using it")
        rejected = true
    }
    assert(rejected)
    assert(local == [3, 1, 2])
    assert(copy == [3, 1, 2, 9, 9])
    local.append(4)
    assert(local == [3, 1, 2, 4])
}
check_local()

var nested = [[3, 1, 2]]
rejected = false
try {
    nested[0].remove_if { item =>
        assert(nested[0] == [3, 1, 2])
        nested[0].insert(0, 9)
        return item == 1
    }
}
catch error: RuntimeError {
    assert(error.message == "a callback cannot change `nested` while `remove_if` is using it")
    rejected = true
}
assert(rejected)
assert(nested == [[3, 1, 2]])
print("callback storage guards preserve aliases and roll back failed work")
