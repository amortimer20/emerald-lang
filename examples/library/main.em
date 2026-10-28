# The demo for the `geometry/` library beside it. Only this file runs; the
# library itself holds declarations. See README.md for how to copy it.

using Geometry
using Geometry.Shapes

const shapes: List[Shape] = [Circle(1.5), Rectangle(3, 4)]

for shape in shapes {
    print(describe(shape))
}
print("total area: #{total_area(shapes).round_to(2)}")
