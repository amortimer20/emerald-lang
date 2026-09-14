# Section 12 across a project: a qualified enum value, and the same value
# through `using`.

print(Compass.Heading.up, Compass.Heading.up.flipped)
print(Compass.Heading.down == Compass.Heading.up.flipped)

using Compass

const heading: Heading = Heading.down
case heading {
    when Heading.up {
        print("going up")
    }
    when Heading.down {
        print("going down")
    }
}
