# Section 15.1: `to_string` displays a value only through `Textual`, and
# adoption is explicit like every other trait's (11.2). Declaring the method
# alone is a warning, not an error: calling it directly still works, so the
# program runs.
struct Point {
    const x: Int

    func to_string(): String {
        return "(#{self.x})"
    }
}

# Adopting the trait is the other half, and warns about nothing.
struct Marked with Textual {
    const x: Int

    @override
    func to_string(): String {
        return "(#{self.x})"
    }
}

print(Point(1).to_string(), Marked(2))
