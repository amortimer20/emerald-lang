## List<T> as a parameter, a return type, a field, and nested — none of which could
## be written down before.
func total(xs: List<Int>): Int {
    return xs.sum()
}

func shout(names: List<String>): List<String> {
    return names.map { n => n.upper() }
}

func rows_in(grid: List<List<Int>>): Int {
    var n = 0
    for row in grid { n += row.count() }
    return n
}

print(total([1, 2, 3]))
print(shout(["ada", "bo"]).join(", "))
print(rows_in([[1, 2], [3]]))

## Nullable list.
var cache: List<String>? = nothing
print(cache.or(["empty"]).join(""))

class Report {
    var rows: List<String>

    constructor(rows: List<String>) {
        self.rows = rows
    }

    func add_row(text: String) {
        self.rows.add(text)
    }

    func lines(): List<String> {
        return self.rows
    }
}

var r = Report(["a"])
r.add_row("b")
print(r.lines().join("-"))
