## What the rule deliberately leaves alone.

# A function that gives nothing back needs no annotation.
func announce(name: String, quiet?: Bool) {
    return unless quiet?
    print("announcing #{name}")
}

# An abstract declaration is a contract, and an unannotated one asks for nothing in
# particular on purpose -- which is what the operator traits are built on.
trait Scalable {
    abstract func scale(factor)
}

struct Weight with Scalable {
    var grams: Int

    func scale(factor: Int): Weight {
        return Weight(self.grams * factor)
    }
}

# A lambda still infers, because its type comes from where it is handed to.
var doubled = [1, 2, 3].map { n => n * 2 }

announce("here", true)
print(Weight(10).scale(3).grams)
print(doubled)
