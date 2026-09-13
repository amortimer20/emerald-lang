# Section 14.1, for type-level fields: they are set up in declaration order, so
# a value can read only the fields above it.
struct Grid {
    var Grid.area = Grid.width * Grid.height
    var Grid.width = 4
    var Grid.height = 3
}
