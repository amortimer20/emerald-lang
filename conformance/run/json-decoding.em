# Section 15.9: Json.decode reads a document directly into a checked program
# type. Extra object fields are ignored; optional and defaulted fields may be
# absent as the type declares.
enum Status { ready, done }

struct Score {
    const name: String
    const points: Int
    const note: String?
    const status: Status
    const tags: List[String]
    const flags: Dict[String, Bool]
}

struct Settings {
    const name: String
    const volume: Int = 5
    const note: String?
}

const score = Json.decode("{\"name\": \"Ada\", \"points\": 120, \"status\": \"ready\", \"tags\": [\"new\"], \"flags\": {\"verified\": true}, \"ignored\": 1}", as: Score)
print(score.name, score.points, score.note, score.status, score.tags, score.flags)
print(Json.decode("[1, 2, 3]", as: List[Int]))
print(Json.decode("{\"first\": [true, false]}", as: Dict[String, List[Bool]]))
const settings = Json.decode("{\"name\": \"Emerald\"}", as: Settings)
print(settings.name, settings.volume, settings.note)
print(Json.decode("\"2026-09-26\"", as: Date), Json.decode("\"09:05:00\"", as: Time))
