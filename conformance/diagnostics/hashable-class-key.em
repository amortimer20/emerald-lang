# Section 8.3: `Hashable` does not make a class a dictionary key.
class Tag with Hashable {
    const name: String

    constructor(name: String) {
        self.name = name
    }

    @override
    func equals(other: Tag): Bool {
        return self.name == other.name
    }

    @override
    func hash(): Int {
        return self.name.count
    }
}

const counts: Dict[Tag, Int] = []
