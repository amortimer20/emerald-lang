## Structs: a named group of fields, and the value you build from them.
##
## A struct is a value type. Assigning one or passing it along gives the other
## side its own copy, so a change on one side never shows up on the other.
##
## Run it with `emerald run examples/structs.em`.

## Every field says whether it can change. Without a constructor of its own, a
## struct is built by passing one value per field, in the order they are
## written.
struct Point {
    var x: Float
    var y: Float
}

## A field with a default can be left out when the value is built. Name the
## fields you do pass when they are not the first ones.
struct Marker {
    var label: String = "here"
    var at: Point
}
print(Marker(at: Point(1, 2)), Marker("there", Point(0, 0)))

var start = Point(0, 0)
var finish = start
finish.x = 3
finish.y = 4
print(start, finish)

## A constructor decides how a value is built. `self` is the value being built,
## and every field has to be set before the constructor finishes. A `const`
## field is set here once and never changes afterwards.
struct Trip {
    const name: String
    var stops: [Point]
    var distance: Float

    constructor(name: String, from: Point, to: Point) {
        self.name = name
        self.stops = [from, to]
        const dx = to.x - from.x
        const dy = to.y - from.y
        self.distance = (dx * dx + dy * dy) ** 0.5
    }
}

var trip = Trip("to the corner", start, finish)
print("#{trip.name} is #{trip.distance} long")

## A method belongs to the struct and sees the value it is called on as
## `self`. One that changes `self` can only be called on something that can
## change, such as a `var`; one that only reads can be called on anything.
struct Tally {
    var marks: [String]

    func mark(label: String) {
        self.marks.append(label)
    }

    func summary(): String {
        return "#{self.marks.count} marks"
    }

    ## A property reads like a field but is worked out each time it is read.
    const latest: String {
        return self.marks.last.or("none yet")
    }
}

var tally = Tally([])
tally.mark("first")
tally.mark("second")
print(tally.summary(), tally.latest)

## A field can be changed through as long a path as it takes, and a list in a
## field changes in place like any other.
trip.stops[1].y = 8
trip.stops.append(Point(0, 8))
print(trip.stops)

## `finish` was copied into the trip, so the trip's changes stay there.
print(finish)
