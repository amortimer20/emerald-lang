# Default parameter values (§3.2)

func greet(name: String, greeting: String = "Hello"): String {
    return "#{greeting}, #{name}!"
}

print(greet("Ana"))                 # Hello, Ana!
print(greet("Bo", "Welcome"))       # Welcome, Bo!

# A default is an ordinary expression, evaluated where the parameter is bound — so it
# can use a parameter to its left.
func box(width: Int, height: Int = width): String {
    return "#{width} by #{height}"
}

print(box(4))
print(box(4, 9))

# It is evaluated on every call that leaves the argument out, not once when the
# function is declared.
#
# Python evaluates it once, which is why `def f(x=[])` quietly shares a single list
# between every call — a bug famous enough to have a name, hiding somewhere a
# beginner has no reason to look. Here there is nothing to share.
var issued = 0

func next_ticket(): Int {
    issued += 1
    return issued
}

func serve(who: String, ticket: Int = next_ticket()): String {
    return "##{ticket} #{who}"
}

print(serve("first in line"))
print(serve("second in line"))
print(serve("has their own", 500))   # the default is not evaluated at all
print("tickets issued: #{issued}")

# Constructors and methods take them too.
class Coffee {
    var size: String
    var shots: Int

    constructor(size: String = "medium", shots: Int = 2) {
        self.size = size
        self.shots = shots
    }

    func describe(loud?: Bool = false): String {
        var text = "#{self.size}, #{self.shots} shots"
        return if loud? then text.upper() else text
    }
}

print(Coffee().describe())
print(Coffee("large").describe())
print(Coffee("large", 4).describe(true))

# Once a parameter has a default, the ones after it need one too — arguments are
# matched by position, and there is no way to skip one:
#
#     func greet(greeting: String = "Hi", name: String)    # rejected
