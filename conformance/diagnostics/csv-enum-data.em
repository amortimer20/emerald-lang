# Section 12: CSV refuses an enum carrying data.
enum Shape {
    circle(radius: Float)
    square(side: Float)
}

struct Row {
    const name: String
    const shape: Shape
}

print(Csv.encode([Row(name: "a", shape: Shape.circle(radius: 1.0))]))
const rows = Csv.decode("name,shape\na,circle", as: List[Row])
