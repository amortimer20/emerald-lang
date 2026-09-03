# Attributes: a fixed vocabulary the compiler knows (§3.8)
#
# Attributes are not macros. They are declarative, they generate no code, and a program
# cannot invent one — which is what lets an unknown name be an error you can act on
# rather than a line that silently does nothing.
#
# There are four: @export, @test, @mirrors, @name.

# @mirrors says a type follows a foreign API's shape. Its names came from somewhere else
# and are not yours to change, so the snake_case rule has nothing to say about them.
@mirrors
class WndClassEx {
    var cbSize: Int
    var lpszClassName: String

    constructor(cbSize: Int, lpszClassName: String) {
        self.cbSize = cbSize
        self.lpszClassName = lpszClassName
    }

    func GetAtom(): Int {
        return self.cbSize
    }
}

print("mirrored: #{WndClassEx(48, "Main").GetAtom()}")

# Without @mirrors, every one of those names would warn — forever, on a type you cannot
# rename. That is the whole reason the attribute exists.

# @export marks a field for a Unity-style host to show in its editor. @name overrides the
# name a member is emitted under, for the cases where the automatic mapping reads badly:
# `any?` would become IsAny, where .NET says Any().
class PlayerController {
    @export
    var speed = 5.0

    @name("Any")
    func any?(): Bool {
        return self.speed > 0.0
    }

    func update() {
        print("moving at #{self.speed}")
    }
}

var player = PlayerController()
player.update()
print("any? #{player.any?}")

# @test marks a function for the test runner.
@test
func speed_is_positive?(): Bool {
    return PlayerController().speed > 0.0
}

print("test passes: #{speed_is_positive?()}")

# Three of the four describe things for a backend that does not exist yet, so they
# generate nothing today. They are checked anyway — an attribute that is accepted and
# quietly ignored teaches you it works.
