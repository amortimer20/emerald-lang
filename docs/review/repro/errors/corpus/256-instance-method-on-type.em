# Mistake: calling an instance method on the type (line 8). Source: Altadmri & Brown 2015 (Blackbox), mistake M.
class Dog {
    var name: String
    func speak() {
        print("Woof")
    }
}
Dog.speak()
