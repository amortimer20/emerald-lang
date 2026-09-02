## Array<T> as a parameter, a return type, a field, and nested — none of which could
## be written down before.
func total(xs: Array<Int>): Int {
    return xs.sum
}

func shout(names: Array<String>): Array<String> {
    return names.map { n => n.upper() }
}

func rows_in(grid: Array<Array<Int>>): Int {
    var n = 0
    for row in grid { n += row.count }
    return n
}

print(total([1, 2, 3]))
print(shout(["ada", "bo"]).join(", "))
print(rows_in([[1, 2], [3]]))

## Nullable array.
var cache: Array<String>? = nothing
print(cache.or(["empty"]).join(""))

class Report {
    var rows: Array<String>

    constructor(rows: Array<String>) {
        self.rows = rows
    }

    func add_row(text: String) {
        self.rows.add(text)
    }

    func lines(): Array<String> {
        return self.rows
    }
}

var r = Report(["a"])
r.add_row("b")
print(r.lines().join("-"))
