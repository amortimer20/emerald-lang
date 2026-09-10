# A to_string that prints the value it describes calls itself forever. Reported, rather
# than left to end the process on a stack overflow.
class Loop {
    var n: Int
    constructor(n: Int) { self.n = n }

    func to_string(): String {
        return "I am #{self}"
    }
}

print(Loop(1))
