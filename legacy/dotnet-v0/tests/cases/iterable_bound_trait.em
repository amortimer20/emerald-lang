## One function, every family that walks. Iterable<Item=Int> is a trait named as a type
## with its associated type answered where the trait is named — which is the only way a
## caller can say what one means, since `type Item = Int` needs a class to be written in
## and a parameter list is not one.
##
## The two built-ins here never declared anything: List and Set predate the trait and are
## not classes at all. What makes them fit is that they walk Ints, which is the whole of
## what the annotation asked about.

class Deck with Iterable {
    type Item = Int

    var values: List<Int>

    constructor(values: List<Int>) {
        self.values = values
    }

    func each(step: func(Int)) {
        for value in self.values {
            step(value)
        }
    }
}

func total(items: Iterable<Item=Int>): Int {
    var sum = 0
    items.each { n => sum += n }
    return sum
}

print(total([1, 2, 3]))
print(total([1, 2, 3, 3].to_set()))
print(total(1..10))
print(total(Deck([10, 20])))

## The rest of what a bare Iterable reference reaches: everything whose answer the
## annotation already settled, because Item is what all of these depend on.
func describe(items: Iterable<Item=String>): String {
    return "#{items.count()} of them, first #{items.to_list().first().or("none")}"
}

print(describe(["ace", "king"]))
print(describe(Deck([]).to_list().map { n => "#{n}" }))
