## A bare name inside a type that is one of its own members is a missing receiver, not an
## undeclared variable. "Declare it first: var contents = ..." answered `return contents`
## by suggesting a second, unrelated variable — confidently wrong, which §3.6 rates worse
## than saying nothing.
class Box {
    var contents: String

    constructor(contents: String) { self.contents = contents }

    func peek(): String { return contents }
}
