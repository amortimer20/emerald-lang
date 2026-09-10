## A class's own method replaces what a trait provided under that name, rather than
## overloading it — otherwise mixing in a trait would silently overload every method you
## wrote to replace one of its defaults.
trait Loud {
    abstract func volume(): Int
    func shout(): String { return "trait version" }
}

class Radio with Loud {
    func volume(): Int { return 11 }
    override func shout(): String { return "class version" }
}

class Siren with Loud {
    func volume(): Int { return 120 }
}

print(Radio().shout())
print(Siren().shout())
