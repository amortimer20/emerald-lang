# Section 15.9: JSON text is Unicode, and columns count characters as
# Emerald's own diagnostics do.
const document = Json.parse("{\"greeting\": \"caf\\u00e9 \\ud83d\\ude00\", \"名前\": \"エメラルド\", \"first name\": \"Ada\", \"quote\": \"\\\"hi\\\" \\\\ \\/ \\b\\f\\n\\r\\t\"}")
print(document.get("greeting").string())
print(document.get("greeting").string().count)
print(document.get("名前").string())
print(document)

# A key that does not read as a name is written in brackets in a path.
for key in ["first name", "名前", "_id", "2nd", ""] {
    try {
        Json.parse("{\"#{key}\": {}}").get(key).get("missing")
    }
    catch error: JsonError {
        print(error.message)
    }
}

# Two keys that are the same text once normalized are a duplicate, as they
# would be in a Dict.
try {
    Json.parse("{\"caf\\u00e9\": 1, \"cafe\\u0301\": 2}")
}
catch error: JsonError {
    print(error.message)
}
print(Json.parse("{\"caf\\u00e9\": 1}").get("cafe\u{301}").int())

# Columns count characters, not bytes.
try {
    Json.parse("{\"émoji 😀\": 1,}")
}
catch error: JsonError {
    print(error.message)
}

# A byte-order mark before the document is allowed.
print(Json.parse("\u{FEFF}[1]"))
