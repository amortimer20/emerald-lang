# Inside a type's own code, a member is still reached through `self` or through
# the type (10.4), never by its bare name.
struct Counter {
    var count: Int
    var Counter.made = 0

    constructor(count: Int) {
        self.count = count
        made += 1
    }

    func bump() {
        count += 1
        show()
    }

    # A function nested in a method is part of the method's code.
    func report() {
        announce()
        func announce() {
            print(count)
        }
    }

    func show() {
        print(this.count)
    }

    func Counter.make(): Counter {
        return Counter(count)
    }
}
