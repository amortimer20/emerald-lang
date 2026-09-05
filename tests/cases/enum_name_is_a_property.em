## An enum value carries a name and nothing else, so that name is read rather than called.
## Its to_string is a method beside it, and takes parentheses like every other method.
enum Colour { RED, GREEN, BLUE }

var c = Colour.GREEN
print(c.name)
print(c.to_string())
