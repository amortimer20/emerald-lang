## What the read-before-assignment check deliberately allows.
class Ok {
    var a: String
    var b: Int
    var c: String?
    var d: Int = 9

    constructor(a: String, flag?: Bool) {
        self.a = a
        print(self.a.count())        # assigned on the line above
        print(self.c.or("none"))     # nullable, so nothing is a legal value for it
        print(self.d)                # given a value where it is declared

        # Assigned on both sides, so control cannot arrive having done neither.
        if flag? { self.b = 1 } else { self.b = 2 }
        print(self.b)
    }
}

print(Ok("hi", true).b)
