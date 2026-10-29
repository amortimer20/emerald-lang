# Section 4.4: two classes that share only a trait, with no common base class, are not
# inferred to that trait; they still need an explicit annotation.
trait Speaker {
    func speak(): String
}

class Dog with Speaker {
    @override
    func speak(): String {
        return "Woof"
    }
}

class Robot with Speaker {
    @override
    func speak(): String {
        return "Beep"
    }
}

var speakers = [Dog(), Robot()]
const annotated: List[Speaker] = [Dog(), Robot()]
