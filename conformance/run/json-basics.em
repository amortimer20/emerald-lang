# Section 15.9: parsing a document and walking it by kind.
const settings = Json.parse("""
{
  "player": "Ada",
  "volume": 7,
  "ratio": 0.5,
  "fullscreen": false,
  "theme": null,
  "scores": [120, 95.5, 3.0, 1e2],
  "window": {"width": 800, "height": 600}
}
""")

print(settings)
print(settings.kind, settings.count)
print(settings.keys())

# Conversions, each for the one kind it reads.
print(settings.get("player").string())
print(settings.get("volume").int(), settings.get("volume").float())
print(settings.get("ratio").float())
print(settings.get("fullscreen").bool())
print(settings.get("theme").null?(), settings.get("player").null?())

# A whole number reads as an Int however it is written; a Float stays one when
# it is written back out.
for score in settings.get("scores").list() {
    print(score, score.kind, score.int_maybe(), score.float())
}
print(settings.get("scores").at(1))

# The _maybe forms give nothing for the wrong kind or a missing part.
print(settings.get_maybe("missing"), settings.get("player").get_maybe("x"))
print(settings.get("scores").at_maybe(4), settings.get("scores").at_maybe(-1))
print(settings.get("player").int_maybe(), settings.get("volume").string_maybe())
print(settings.get("theme").bool_maybe(), settings.get("volume").list_maybe())
print(settings.get("scores").object_maybe())
print(settings.get_maybe("volume")?.int_maybe().or(5))
print(settings.get_maybe("brightness")?.int_maybe().or(5))

# An object's entries keep the document's order.
for (name, size) in settings.get("window").object() {
    print(name, size.int())
}

# Every kind as the root of a document.
for text in ["null", "true", "-0", "-0.0", "\"hi\"", "[]", "{}", " [ [ ] , { } ] "] {
    const document = Json.parse(text)
    print(document, document.kind)
}

# Equality is by JSON meaning: numbers by value, objects in any order, and
# where a value came from does not matter.
print(Json.parse("1") == Json.parse("1.0"), Json.parse("1") == Json.parse("1e0"))
print(Json.parse("{\"a\": 1, \"b\": [true]}") == Json.parse("{\"b\": [true], \"a\": 1.0}"))
print(Json.parse("[1, 2]") == Json.parse("[2, 1]"), Json.parse("null") == Json.parse("false"))
print(settings.get("window").get("width") == Json.parse("800"))

print(Json.parse_maybe("[1, 2,]"), Json.parse_maybe("[1, 2]"))
