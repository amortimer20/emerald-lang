## KNOWN HOLE, and the quietest of the three: this one does not even fail loudly.
##
## Passing self out of a constructor hands another object a reference to something that is
## not built yet. The registry reads label at a moment when it is still nothing, prints
## it, and the program exits successfully -- so a half-built object leaked into a data
## structure and nothing anywhere said so.
##
## Same local rule as the others: until every required field is definitely assigned, self
## is not a value that may be passed anywhere.

class Registry {
    var seen: List<String> = []

    func record(w: Widget) {
        self.seen.add("recorded #{w.label}")
    }
}

class Widget {
    var label: String

    constructor(into: Registry) {
        into.record(self)
        self.label = "ok"
    }
}

var r = Registry()
Widget(r)
print(r.seen.first())
print(Widget(r).label)
