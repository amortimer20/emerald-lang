## An inherited method is checked against the base's signature.
class Animal {
    var name: String
    constructor(name: String) { self.name = name }
    func speak(volume: Int): String { return "#{self.name} at #{volume}" }
}

class Dog extends Animal {
}

print(Dog("rex").speak("loud"))
