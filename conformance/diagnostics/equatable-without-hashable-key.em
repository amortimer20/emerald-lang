# Section 8.4: a struct that adopts `Equatable` without also adopting
# `Hashable` cannot be a dictionary key or set member. Its default structural
# hash could then disagree with its custom `equals`, which would let a set or
# dictionary hold two "equal" elements as if they were different.
struct Weird with Equatable {
    var a: Int
    var b: Int

    @override
    func equals(other: Weird): Bool {
        return self.a == other.a
    }
}

const dict: Dict[Weird, Int] = [Weird(1, 100): 1]
const set: Set[Weird] = [Weird(1, 100), Weird(1, 200)]
