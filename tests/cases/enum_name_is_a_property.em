## An enum value carries a name and nothing else, so that name is read rather than called.
## Its to_string is a method beside it, and takes parentheses like every other method.
enum Color { RED, GREEN, BLUE }

var c = Color.GREEN
print(c.name)
print(c.to_string())
