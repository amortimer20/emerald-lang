# Section 12: an enum's values and members share one set of names, and an
# enum is neither constructed, extended, nor adopted.

enum Light {
    red
    green
    red
    amber

    func amber(): Int {
        return 1
    }
}

class Lamp extends Light {
}

struct Holder with Light {
}

const light = Light()
print(Light.red == 3)
print(Light.red < Light.green)

# A value is a type-level member, so assigning one through a value names that.
var chosen = Light.red
chosen.green = Light.green
