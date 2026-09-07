## KNOWN HOLE, and the sharper half of known_method_call_before_init.
##
## Base's constructor assigns every field Base declares, so by any check local to Base it
## is finished and the call to describe is fair. But describe is overridden, and the
## override reads a field Derived has not assigned yet -- Derived's constructor is still
## inside super(). A rule that only asks "are this class's own fields assigned" passes
## this program, which is why the inheritance case needs its own answer rather than
## falling out of the local one.

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
