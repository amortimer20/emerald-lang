## Several functions of one name, told apart by what they take (§3.2).
func describe(n: Int): String { return "the number #{n}" }
func describe(s: String): String { return "the word #{s}" }
func describe(b: Bool): String { return "the answer #{b}" }

print(describe(42))
print(describe("hi"))
print(describe(true))

## Or by how many.
func area(side: Float): Float { return side * side }
func area(width: Float, height: Float): Float { return width * height }

print(area(3.0))
print(area(3.0, 4.0))

## Containers and user types are distinguishable too.
class Dog {
    var name: String
    constructor(name: String) { self.name = name }
}

func show(items: List<Int>): String { return "a list of #{items.count()}" }
func show(d: Dog): String { return "a dog called #{d.name}" }

print(show([1, 2, 3]))
print(show(Dog("rex")))
