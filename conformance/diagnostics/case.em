# Section 6.3: a `case` that produces a value covers everything, alternatives
# compare with the subject and are not repeated, and arms agree on a type.

enum Direction {
    north
    east
    south
}

const heading = Direction.north
const partial = case heading {
    when Direction.north then 1
    when Direction.east then 2
}
const numbers = case 5 {
    when 1 then "one"
}

case heading {
    when Direction.north, Direction.north {
        print("north")
    }
    when "south" {
        print("south")
    }
}

const mixed = case heading {
    when Direction.north then 1
    else then "elsewhere"
}

case {
    when 1 {
        print(1)
    }
}

# A statement `case` over an `Int` may match nothing, so this can fall off
# the end.
func first_prize(place: Int): Int {
    case place {
        when 1 {
            return 100
        }
    }
}

# A subject that may be absent needs `nothing` covered too.
const maybe_on: Bool? = true
const switch_label = case maybe_on {
    when true then "on"
    when false then "off"
}

trait Named {
    const name: String
}

struct Pet with Named {
    const name: String
}

const pet: Named = Pet("Rex")
case pet {
    when Pet("Rex") {
        print("Rex")
    }
}
