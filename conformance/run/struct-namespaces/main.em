using LeftMarker = Left.Marker
using RightMarker = Right.Marker
using L = Left

func keep_left(value: LeftMarker): LeftMarker {
    return value
}

const left: Left.Marker = keep_left(LeftMarker())
const right: RightMarker = RightMarker()
const aliased: L.Marker = L.Marker()

print(left)
print(right)
print(aliased)
