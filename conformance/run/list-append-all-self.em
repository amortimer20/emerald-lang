# Appending a list to itself appends what it held before the call, once.

var items = [1, 2, 3]
items.append_all(items)
print(items)

const empty: List[Int] = []
var none = empty
none.append_all(none)
print(none)

# A list reached through another list or a struct field behaves the same.
var rows = [[1], [2]]
rows[0].append_all(rows[0])
print(rows)

struct Holder {
    var values: List[String]
}
var holder = Holder(["a", "b"])
holder.values.append_all(holder.values)
print(holder.values)
