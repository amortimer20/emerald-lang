# Section 4.4: a trait-typed value, struct, or enum receives no "always false" warning
# from `is`, since its possible value set needs a separate analysis. The one warning
# here is the pair of unrelated classes, which no instance can be.
trait Speaker {
    func speak(): String
}

struct Parrot with Speaker {
    @override
    func speak(): String {
        return "Hello"
    }
}

class Robot {
}

class Rock {
}

enum Color {
    red
    green
}

func test(speaker: Speaker, parrot: Parrot, color: Color, robot: Robot) {
    print(speaker is Robot)
    print(parrot is Robot)
    print(color is Robot)
    print(robot is Rock)
}
