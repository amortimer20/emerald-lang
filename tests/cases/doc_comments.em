## Draws a circle centered on the pen position.
##
## The radius is in pixels. A circle of zero radius draws nothing rather than
## failing, which is what makes it safe to call in a loop.
##
## @param radius  distance from center to edge, in pixels
## @returns       the number of pixels actually painted
func draw_circle(radius: Int): Int {
    return radius * 6
}

## A documented function with nothing to say about its parts is still fine --
## an undocumented parameter is never reported, because warning on every partly
## documented function is how a warning becomes noise.
func area(width: Int, height: Int): Int {
    return width * height
}

print(draw_circle(3))
print(area(2, 5))
