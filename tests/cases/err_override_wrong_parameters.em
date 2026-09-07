## override is a claim about one version, so the parameters have to match the one being
## replaced. This draw() sits below a draw(Int) and replaces nothing.
class Shape {
    func draw(times: Int): String { return "shape x#{times}" }
}

class Circle extends Shape {
    override func draw(): String { return "circle" }
}
