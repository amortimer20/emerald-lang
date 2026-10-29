# 4.4: `is` tests a value's runtime type, and `type_name` spells its concrete
# runtime type. Inside a generic body both use the static type `T` instead.
func describe[T](x: T): T {
    print(x.type_name, x is Int, x is String)
    return x
}

func wrap[T](x: T): List[T] {
    const items = [x]
    print("inside:", items.type_name)
    return items
}

const n = describe(3)
print(n.type_name)
describe("text")
print("outside:", wrap(1).type_name)
