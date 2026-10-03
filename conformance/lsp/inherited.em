class Parent {
    const name: String
    ## The parent's greeting.
    func greet(): String {
        return self.name
    }
    func _secret(): Int {
        return 1
    }
}
class Child extends Parent {
    constructor(name: String) {
        super(name)
    }
    ## The child's answer.
    func answer(): Int {
        return 42
    }
}
const child = Child("Ada")
child./*cursor*/
