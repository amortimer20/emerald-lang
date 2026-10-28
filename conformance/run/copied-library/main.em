# 14.4: a library copied to the top of another project works unchanged,
# because it names itself (`Geometry.Shapes`) rather than relying on where it
# was written.

const room = Geometry.Shapes.Rectangle(5, 4)
print(Geometry.describe(room))
print(Geometry.total_area([room, Geometry.Shapes.Circle(1)]).round_to(2))
