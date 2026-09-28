# Section 15.9: Json.encode writes ordinary program values according to their
# checked types, preserving struct field and dictionary insertion order.
enum Status { ready, done }

struct Score {
    const name: String
    const points: Int
    const bonus: Float
    const note: String?
    const status: Status
    const played_on: Date
    const tags: List[String]
    const details: Dict[String, Bool]
}

const score = Score("Ada", 120, 3.0, nothing, Status.ready, Date(2026, 9, 26), ["new", "high"], ["verified": true, "shared": false])
print(Json.encode(score))
print(Json.encode([score], pretty: true))
print(Json.encode(score, pretty: true).starts_with?("{\n"))

# Scalars, an optional absence, lists, dictionaries, enums, and date/time
# values all use their natural JSON representation.
const absent: String? = nothing
const present: String? = "yes"
print(Json.encode("text"), Json.encode(42), Json.encode(2.0), Json.encode(false), Json.encode(absent), Json.encode(present))
print(Json.encode(["active": true, "shared": false]))
print(Json.encode(Status.done), Json.encode(Date(2026, 1, 2)), Json.encode(Time(9, 5)), Json.encode(DateTime(2026, 1, 2, 3, 4)), Json.encode(Instant.from_unix_seconds(0)))
