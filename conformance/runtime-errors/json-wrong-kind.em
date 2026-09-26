# A JsonError that nothing handles is reported at the program's own call,
# not inside the prelude code that raised it, with the path in the document.
func score(text: String): Int {
    return Json.parse(text).get("scores").at(1).int()
}

print(score("{\"scores\": [10, \"12\"]}"))
