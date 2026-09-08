## The mechanism itself, apart from the prelude's own Iterable: a user can write the same
## shape for a trait of their own, with a generic method resolved the same way map's is.
trait Numbered {
    type Item
    abstract func each(step: func(Item))

    func doubled<R>(f: func(Item): R): List<R> {
        var result: List<R> = []
        self.each { item => result.add(f(item)) }
        return result
    }
}

class Row with Numbered {
    type Item = Int
    var values: List<Int>
    constructor(values: List<Int>) { self.values = values }
    func each(step: func(Int)) {
        for v in self.values { step(v) }
    }
}

var row = Row([1, 2, 3])
print(row.doubled { n => n * 2 }.join(", "))
print(row.doubled { n => n.to_string() }.join(", "))
