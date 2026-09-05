## The mistake requiring parentheses creates, and the reason a statement that throws its
## value away is an error: without that rule this line would run nothing and say nothing.
class Dog {
    func speak(): String { return "Woof" }
}

var rex = Dog()
rex.speak
