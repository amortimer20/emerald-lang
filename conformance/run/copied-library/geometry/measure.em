# The library writes its own name, `Geometry.Shapes`, rather than `Shapes`, so
# its paths still hold once `geometry/` is copied to the top of a project.

## The shape's name and its area, to two decimal places.
func describe(shape: Geometry.Shapes.Shape): String {
    return "#{shape.name()}: #{shape.area().round_to(2)}"
}

## The areas of every shape, added up.
func total_area(shapes: List[Geometry.Shapes.Shape]): Float {
    return shapes.map { shape => shape.area() }.sum()
}
