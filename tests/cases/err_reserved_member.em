## or and must belong to the ?. A class that declared one would decide which meaning
## `.must` had by the receiver's declared type rather than by what is written.
class Box {
    var contents: String

    constructor(contents: String) { self.contents = contents }

    func must(): String { return self.contents }
}
