# Section 15.9: a large document, and nesting up to and past its limit.
var text = "["
for index in 0..<5000 {
    if index > 0 {
        text += ","
    }
    text += "{\"id\": #{index}, \"name\": \"item #{index}\", \"tags\": [\"a\", \"b\"], \"price\": #{index}.25}"
}
text += "]"

const items = Json.parse(text)
print(items.count)
var total = 0.0
for item in items.list() {
    total += item.get("price").float()
}
print(total)
print(items.at(4999).get("name").string())
print(Json.parse(items.to_string()) == items)

func nested(depth: Int): String {
    var opening = ""
    var closing = ""
    for _ in 0..<depth {
        opening += "["
        closing += "]"
    }
    return opening + closing
}

var deepest = Json.parse(nested(512))
var levels = 1
while deepest.count > 0 {
    deepest = deepest.at(0)
    levels += 1
}
print(levels)

try {
    Json.parse(nested(513))
}
catch error: JsonError {
    print(error.message)
}
