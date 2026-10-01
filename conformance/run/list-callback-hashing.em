var items: List[Key] = []
var entries: List[(Key, Int)] = []
var changing = false
var dictionary = false
var calls = 0

struct Key with Hashable {
    const id: Int

    @override
    func hash(): Int {
        return 0
    }

    @override
    func equals(other: Self): Bool {
        calls += 1
        assert(items.map { item => item.id } == [2, 1, 2])
        if changing {
            if dictionary {
                entries.append((Key(9), 9))
            }
            else {
                items.append(Key(9))
            }
        }
        return self.id == other.id
    }
}

func exercise(method: String) {
    case method {
        when "to_set" { assert(items.to_set().count == 2) }
        when "frequencies" { assert(items.frequencies().count == 2) }
        when "unique_by" { assert(items.unique_by { item => item }.count == 2) }
        when "group_by" { assert(items.group_by { item => item }.count == 2) }
        when "associate" { assert(items.associate { item => (item, item.id) }.count == 2) }
        when "associate_by" { assert(items.associate_by { item => item }.count == 2) }
        when "to_dictionary" { assert(entries.to_dictionary().count == 2) }
    }
}

for method in ["to_set", "frequencies", "unique_by", "group_by", "associate", "associate_by", "to_dictionary"] {
    for requested in [false, true] {
        items = [Key(2), Key(1), Key(2)]
        entries = [(Key(2), 2), (Key(1), 1), (Key(2), 2)]
        changing = requested
        dictionary = method == "to_dictionary"
        calls = 0
        var rejected = false
        try {
            exercise(method)
        }
        catch error: RuntimeError {
            const name = if dictionary then "entries" else "items"
            assert(error.message == "a callback cannot change `#{name}` while `#{method}` is using it")
            rejected = true
        }
        assert(calls > 0)
        assert(rejected == requested)
        assert(items.map { item => item.id } == [2, 1, 2])
        assert(entries.count == 3)
    }
}
print("key-building callbacks read safely and reject source mutation")
