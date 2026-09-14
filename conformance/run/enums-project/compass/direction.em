# An enum declared in a namespace is reached through it.

enum Heading {
    up
    down

    const flipped: Heading {
        return case self {
            when Heading.up then Heading.down
            when Heading.down then Heading.up
        }
    }
}
