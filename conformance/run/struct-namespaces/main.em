using LeftMarker = Left.Marker
using RightMarker = Right.Marker

func keep_left(value: LeftMarker): LeftMarker {
    return value
}

const left = keep_left(LeftMarker())
const right: RightMarker = RightMarker()

print(left)
print(right)
