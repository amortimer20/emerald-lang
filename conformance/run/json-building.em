# Section 15.9: build a JSON document from Json values, then write it in the
# compact and indented forms. Builders preserve a Float's visible `.0` and a
# dictionary's insertion order.
const document = Json.from_object([
    "name": Json.from_string("Ada"),
    "age": Json.from_int(42),
    "score": Json.from_float(3.0),
    "active": Json.from_bool(true),
    "note": Json.null,
    "items": Json.from_list([Json.from_string("new"), Json.from_bool(false)]),
])

print(document)
print(document.kind, document.count)
print(document.get("name").string(), document.get("age").int(), document.get("score").float(), document.get("active").bool(), document.get("note").null?())
print(document.get("items").at(0).string(), document.get("items").at(1).bool())
print(Json.encode(document))
print(Json.encode(document, pretty: true))
print(Json.parse(Json.encode(document)) == document, Json.parse(Json.encode(document, pretty: true)) == document)
print(Json.from_float(-0.0), Json.from_float(3.0).int(), Json.from_float(3.5).int_maybe())

# A built nested document has fresh paths, so an error names the position in
# this document rather than where a value may have come from before building.
try {
    Json.from_list([Json.parse("{\"old\": \"text\"}").get("old")]).at(0).int()
}
catch error: JsonError {
    print(error.message)
}
