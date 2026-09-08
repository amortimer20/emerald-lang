## Iterable's abstract each names a parameter of type Item, and nothing says what Item
## means until something does -- so a class that mixes it in without type Item = ... would
## leave each's own parameter type unresolved forever were this not caught here instead.
class Bag with Iterable {
    var values: List<Int>
    constructor(values: List<Int>) { self.values = values }
    func each(step: func(Int)) {
        for v in self.values { step(v) }
    }
}
