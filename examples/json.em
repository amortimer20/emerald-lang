# JSON: save a known shape, read it back, and inspect an unknown document.
# Run it with `emerald run examples/json.em`.

struct Score {
    const name: String
    const points: Int
}

# A program's own values encode and decode directly.
const scores = [Score("Ada", 120), Score("Grace", 95)]
const saved = Json.encode(scores, pretty: true)
print(saved)
const loaded = Json.decode(saved, as: List[Score])
print("#{loaded[0].name} has #{loaded[0].points} points")

# Walk data whose shape is only known once it arrives.
const response = Json.parse("{\"current\": {\"temperature\": 21.5, \"unit\": \"C\"}}")
const current = response.get("current")
print("#{current.get("temperature").float()}°#{current.get("unit").string()}")

# Build a document when no struct is the right shape.
const event = Json.from_object([
    "name": Json.from_string("launch"),
    "tags": Json.from_list([Json.from_string("news"), Json.from_string("featured")]),
])
print(event)
