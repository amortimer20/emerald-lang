## The same rule, and the reason it cannot be staged on assignment instead.
##
## Base's constructor assigns every field Base declares, so by any measure local to Base
## it is finished and the call is fair. But describe is overridden, and the override reads
## a field Derived has not assigned -- Derived's constructor is still inside super(). So
## "all my fields are set" is not the condition that makes a call on self safe; a base
## constructor cannot see the part of the object below it.
##
## Since Emerald has no sealed, every class is open and every method may be overridden.
## The rule is therefore flat: not in a constructor, at all.

class Base {
    var tag: String

    constructor() {
        self.tag = "base"
        print(self.describe())
    }

    func describe(): String { return "Base #{self.tag}" }
}

class Derived extends Base {
    var extra: String

    constructor() {
        super()
        self.extra = "here"
    }

    override func describe(): String { return "Derived #{self.extra.upper()}" }
}

Derived()
