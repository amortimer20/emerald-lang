## The outer else assigns, so only the innermost arm is missing -- the shape that a
## check looking one level deep would pass.
class MissingInner {
    var n: Int
    constructor(a: Bool, b: Bool) {
        if a {
            if b { self.n = 1 }
        } else {
            self.n = 3
        }
    }
}
