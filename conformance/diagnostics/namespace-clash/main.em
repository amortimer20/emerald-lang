# A module-level declaration whose name is also a directory's namespace
# would make `Shapes.Circle` mean a member of either one.
struct Shapes {
    var sides: Int
}

func Graphics(): Int {
    return 0
}

print(Shapes(3))
