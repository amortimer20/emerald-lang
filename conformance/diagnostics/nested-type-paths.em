# Paths through nested types (14.3): a misspelled value or nested type, a
# nested type reached through a subclass.
class Console {
    enum Color {
        red
    }

    struct Pair {}

    struct _Hidden {}
}

class Animal {
    struct Tag {
        var n: Int
    }
}

class Dog extends Animal {
}

print(Console.Color.purple)
print(Console.Colour.red)
print(Dog.Tag(1))
