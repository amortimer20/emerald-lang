## The same rule caught something that had nothing to do with aliasing. Int widens into
## Float, so List<Float> accepted [1, 2] and then held Ints: the declared element type was
## simply false, and .round_to on an element failed at run time.
##
## A literal is nobody's alias, so it gets the advice that fits it -- the items are right
## here to fix -- rather than an explanation about a second name that does not exist.
var b: List<Float> = [1, 2]

print(b[0].round_to(2))
