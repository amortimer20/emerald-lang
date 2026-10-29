# Probe: TimeZone.local (from TZ, read from the system's zoneinfo) against
# the built-in zone of the same name, at the start of every month 1970-2040.
const name = Program.arguments[0]
const named = TimeZone.named_maybe(name)
if named == nothing {
    print(name, "local=", TimeZone.local, "built-in: unknown")
    exit(0)
}
const zone = named.or(TimeZone.utc)
var differences = 0
var first = ""
for year in 1970..2040 {
    for month in 1..12 {
        const instant = DateTime(year, month, 1).to_instant(TimeZone.utc)
        if TimeZone.local.offset_at(instant) != zone.offset_at(instant) {
            if differences == 0 {
                first = "#{instant} local #{TimeZone.local.offset_at(instant)} built-in #{zone.offset_at(instant)}"
            }
            differences += 1
        }
    }
}
print(name, "local=", TimeZone.local, "differences:", differences, first)
