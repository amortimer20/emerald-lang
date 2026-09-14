# A base class in its own namespace, with a private field and a default that
# reads a module-level value of this file.
const greeting = "hello"

class Animal {
    const name: String
    var _visits: Int = 0

    constructor(name: String) {
        self.name = name
    }

    func greet(word: String = greeting): String {
        self._visits += 1
        return "#{word}, #{self.name} (visit #{self._visits})"
    }
}
