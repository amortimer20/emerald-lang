# Section 11.2: compatible duplicate requirements need one implementation, and a
# writable property requirement subsumes a read-only one of the same type.
trait Walker {
    const name: String

    func move(): String
}

trait Swimmer {
    var name: String

    func move(): String
}

struct Duck with Walker, Swimmer {
    var name: String

    @override
    func move(): String {
        return "#{self.name} waddles and swims"
    }
}

var duck = Duck(name: "Dot")
duck.name = "Dee"
print(duck.move())
