# Section 17.2: a warning (Diagnostic.Severity) is reported, but does not stop
# checking or execution the way an error does. This mixes all three of the
# checker's current warnings into one program that still runs to completion.

enum Direction {
    north
    east
}

func early(): Int {
    return 1
    var never_reached = 2
}

var heading = Direction.north
case heading {
    when Direction.north {
        print("north")
    }
}

var count: Int = 3
if count is Int {
    print("still", early())
}
