# A type-level field's annotation fixes what it holds, as for any binding, and
# one without an annotation holds the type of its value.
func rename() {
    Settings.name = 3
}

struct Settings {
    var Settings.volume: Int = "loud"
    var Settings.name = "main"
}

