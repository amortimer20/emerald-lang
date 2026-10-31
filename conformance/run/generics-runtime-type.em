# Section 4.4: inside a generic body, `is` and `type_name` see the value's
# runtime type, as they do everywhere else (11.3).
func describe[T](x: T): String {
    return "#{x.type_name} #{x is Int} #{x is String}"
}

func wrap[T](x: T): List[T] {
    const items = [x]
    print("inside:", items.type_name)
    return items
}

func inner[U](y: U): String {
    return "#{y.type_name} #{[y].type_name}"
}

func outer[T](x: T): String {
    return inner([x])
}

func nest[T](x: T, depth: Int): String {
    if depth == 0 {
        return x.type_name
    }
    return nest([x], depth - 1)
}

struct Box[T] {
    var item: T

    func show(): String {
        return "#{self.item.type_name} #{self.item is String}"
    }
}

print(describe(3))
print(describe("text"))
print(describe(2.5))
print("outside:", wrap(1).type_name)
print(outer(3))
print(nest(true, 2))
print(Box(item: "a").show())
print(Box(item: 7).show())
