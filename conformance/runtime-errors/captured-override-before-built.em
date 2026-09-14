# Section 10.7: a method taken from an object still being built may be kept,
# but calling it before its class's part is built is a runtime error.
class Guest {
    const name: String

    constructor(name: String) {
        self.name = name
        greet(self)
    }

    func introduce(): String {
        return self.name
    }
}

func greet(guest: Guest) {
    const introduce = guest.introduce
    print(introduce())
}

class TitledGuest extends Guest {
    const title: String

    constructor(name: String, title: String) {
        super(name)
        self.title = title
    }

    @override
    func introduce(): String {
        return "#{self.title} #{self.name}"
    }
}

const plain = Guest("Grace")
const titled = TitledGuest("Ada", "Dr")
