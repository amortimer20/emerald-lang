struct Bag {
    var values: [Int]
}

var bag = Bag([1])
bag.values.append(2)
print(bag.values)

struct Tags {
    var names: {String}
}

# Value semantics hold through a dictionary/set changing method reached by
# field, exactly as they do for a list one.
var a = Tags(["x"])
var b = a
b.names.add("y")
print(a.names)
print(b.names)

struct Lookup {
    var counts: [String: Int]
}

var lookup = Lookup(["a": 1])
lookup.counts.remove("a")
print(lookup.counts)
