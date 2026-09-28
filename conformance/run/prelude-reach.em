# A run checks only the prelude bodies its program can reach, and running any
# other would stop Emerald. Each line below reaches library code without
# naming the type whose bodies run.

# A field of the program's own struct: printing the struct prints the Date.
struct Event {
    const title: String
    const on: Date
}
print(Event("Launch", Date(2026, 9, 28)))

# A base class: the program's error runs RuntimeError's constructor.
class LateError extends RuntimeError {
    constructor(message: String) {
        super(message)
    }
}
try {
    raise LateError("too late")
} catch error: RuntimeError {
    print(error.message)
}

# A type-level function whose result is only a String.
print(Console.plain(Console.style("hi", foreground: Console.Color.green)))

# An enum value displayed, and values sorted by their Ordered comparison.
print(Weekday.monday)
print([Date(2026, 9, 30), Date(2026, 1, 2)].sort())

# Decoding into the program's own type, which holds a Date.
const events = Json.decode("[{\"title\": \"Launch\", \"on\": \"2026-09-28\"}]", as: List[Event])
print(events[0].on.weekday)

# CSV's typed path reaches the same Date parser through an ordinary record.
const csv_events = Csv.decode("title,on\nLaunch,2026-09-28", as: List[Event])
print(csv_events[0].on)
