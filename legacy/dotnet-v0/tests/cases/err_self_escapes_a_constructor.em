## self may not be passed out of a constructor.
##
## This was the quietest of the four failures it fixes: it did not fail at all. The
## registry read label while it was still nothing, printed "recorded nothing", and the
## program exited successfully. A half-built object leaked into a data structure and
## nothing anywhere said so.

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
