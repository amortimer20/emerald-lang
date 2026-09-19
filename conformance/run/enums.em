# Section 12: an enum is a closed set of named values. Each has the enum's
# type, compares with `==`, and shows its qualified name.

enum Direction {
    north
    east
    south
    west

    # Methods and computed properties work on each value.
    const opposite: Direction {
        return case self {
            when Direction.north then Direction.south
            when Direction.east then Direction.west
            when Direction.south then Direction.north
            when Direction.west then Direction.east
        }
    }

    func turned_right(): Direction {
        return case self {
            when Direction.north then Direction.east
            when Direction.east then Direction.south
            when Direction.south then Direction.west
            when Direction.west then Direction.north
        }
    }

    # So do type-level members.
    func Direction.all(): List[Direction] {
        return [Direction.north, Direction.east, Direction.south, Direction.west]
    }
}

const heading = Direction.north
print(heading, heading.opposite, heading.turned_right().turned_right())
print(heading == Direction.north, heading != Direction.east, heading == heading.opposite.opposite)
print(Direction.all())
print("Facing #{heading}, of type #{heading.type_name}")

# Enum values are values: copying one and changing the copy leaves the original.
var facing = heading
facing = facing.turned_right()
print(heading, facing)

# They are stable dictionary keys and set members.
var visits: Dict[Direction, Int] = []
for direction in [Direction.east, Direction.north, Direction.east] {
    visits[direction] = visits[direction].or(0) + 1
}
print(visits)
const seen: Set[Direction] = [Direction.west, Direction.west, Direction.south]
print(seen, seen.contains?(Direction.west))

# A struct can hold one, and structural equality compares it.
struct Step {
    const direction: Direction
    const distance: Int
}

print(Step(Direction.west, 2) == Step(Direction.west, 2), Step(Direction.west, 2) == Step(Direction.east, 2))

# Declaration order creates no ordering; an enum adopts `Ordered` when its
# domain needs one, and any other trait the same way.
trait Described {
    func describe(): String
}

enum Size with Ordered, Described {
    small, medium, large

    const rank: Int {
        return case self {
            when Size.small then 1
            when Size.medium then 2
            when Size.large then 3
        }
    }

    @override
    func compare(other: Self): Int {
        return self.rank - other.rank
    }

    @override
    func describe(): String {
        return "size #{self.rank}"
    }
}

print(Size.small < Size.large, Size.large <= Size.medium, Size.medium >= Size.medium)
const described: Described = Size.large
print(described.describe(), described is Size)

# An optional enum narrows like any optional.
func largest(sizes: List[Size]): Size? {
    var best: Size? = nothing
    for size in sizes {
        if best == nothing or size > best {
            best = size
        }
    }
    return best
}

const chosen = largest([Size.medium, Size.small])
print(largest([]))
if chosen != nothing {
    print(chosen.describe())
}
