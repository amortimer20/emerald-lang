## The whole vocabulary: @export, @test, @mirrors, @name (§3.8).

## @mirrors says this type follows a foreign API's shape, so §3.4's casing rule has
## nothing to say about names the programmer did not choose.
@mirrors
class WndClassEx {
    var cbSize: Int
    var lpszClassName: String

    constructor(cbSize: Int, lpszClassName: String) {
        self.cbSize = cbSize
        self.lpszClassName = lpszClassName
    }

    func GetAtom(): Int { return self.cbSize }
}

print(WndClassEx(48, "Main").GetAtom())

## The other three describe things for a backend that does not exist yet. They are
## checked now, and generate nothing.
class Player {
    @export
    var speed = 5.0

    @name("Any")
    func any?(): Bool { return self.speed > 0.0 }
}

print(Player().speed)
print(Player().any?())

@test
func speed_is_positive?(): Bool {
    return Player().speed > 0.0
}

print(speed_is_positive?())
