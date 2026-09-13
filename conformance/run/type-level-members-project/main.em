using Shapes

print("start")
# Constructing the type is what sets it up here.
const big = Circle(10)
print(big, Shapes.Circle.made)
print(Shapes.Circle.unit(), Circle.unit())
Circle.made += 100
print(Shapes.circles_made())
