# An enum's values are reached through the enum, and never change.

enum Light {
    red
    green
}

Light.red = Light.green
print(Light.blue)
