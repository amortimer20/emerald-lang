## With nothing to choose by, naming an overloaded method is not a question with one
## answer — so it is refused rather than guessed at.
class Greeter {
    func hi(): String { return "hi there" }
    func hi(name: String): String { return "hi #{name}" }
}

func run(f: func(): String) { print(f()) }

var g = Greeter()
var pick = g.hi
run(pick)
