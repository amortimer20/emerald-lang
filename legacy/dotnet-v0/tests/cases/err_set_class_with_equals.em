## A class that says what sameness means cannot be found by identity, and identity is how
## a set finds an object. Two equal-but-distinct customers would both go in, and asking
## for one would miss -- so this is refused rather than answered wrongly.
class Customer with Equatable {
    var email: String
    constructor(email: String) { self.email = email }

    func equals?(other: Customer): Bool { return self.email == other.email }
}

var seen: Set<Customer> = [].to_set()
