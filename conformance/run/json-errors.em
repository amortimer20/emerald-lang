# Section 15.9's JsonError: text that is not JSON says where, and a value of
# the wrong kind says what it is and where it is in the document.
func show(text: String) {
    try {
        print(Json.parse(text))
    } catch error: JsonError {
        print(error.message)
    }
}

show("")
show("   ")
show("[1, 2,]")
show("{\"a\": 1,}")
show("{'a': 1}")
show("['a']")
show("{name: \"Ada\"}")
show("// settings\n{}")
show("[1, /* two */ 2]")
show("NaN")
show("[Infinity]")
show("-Infinity")
show("True")
show("01")
show(".5")
show("1.")
show("2e")
show("+1")
show("1e400")
show("\"never closed")
show("[\"one\",\n \"two]")
show("\"a\\qb\"")
show("\"\\u12\"")
show("\"\\ud83d\"")
show("\"tab\there\"")
show("{\"a\": 1, \"a\": 2}")
show("{\"a\" 1}")
show("[1 2]")
show("{\"a\": 1 \"b\": 2}")
show("[1] [2]")
show("]")

const document = Json.parse("""
{
  "players": [
    {"name": "Ada", "score": "12"},
    {"name": "Grace", "score": 3.5},
    {"name": "Linus", "score": 1e20}
  ],
  "title": "a very long title that goes on for more than forty characters",
  "empty": {},
  "note": null
}
""")

const attempts: List[func(): String] = [
    { => "#{document.get("players").at(0).get("score").int()}" },
    { => "#{document.get("players").at(1).get("score").int()}" },
    { => "#{document.get("players").at(2).get("score").int()}" },
    { => "#{document.get("title").float()}" },
    { => "#{document.get("note").string()}" },
    { => "#{document.get("players").bool()}" },
    { => "#{document.get("empty").list()}" },
    { => "#{document.get("title").object()}" },
    { => "#{document.bool()}" },
    { => "#{document.at(0)}" },
    { => "#{document.get("players").get("name")}" },
    { => "#{document.get("volume")}" },
    { => "#{document.get("empty").get("x")}" },
    { => "#{document.get("players").at(0).get("points")}" },
    { => "#{document.get("players").at(3)}" },
    { => "#{document.get("players").at(-1)}" },
    { => "#{document.get("empty").keys()}" },
    { => "#{document.get("players").keys()}" },
    { => "#{document.get("title").count}" },
    { => "#{Json.parse("[]").at(0)}" },
    { => "#{Json.parse("[7]").at(1)}" },
    { => "#{Json.parse("{\"k1\":1,\"k2\":2,\"k3\":3,\"k4\":4,\"k5\":5,\"k6\":6,\"k7\":7,\"k8\":8,\"k9\":9,\"k10\":10,\"k11\":11,\"k12\":12}").get("k")}" },
]
for attempt in attempts {
    try {
        print(attempt())
    } catch error: JsonError {
        print(error.message)
    }
}

# A JsonError is a RuntimeError.
try {
    Json.parse("nope")
} catch error: RuntimeError {
    print(error.type_name, error.message)
}
