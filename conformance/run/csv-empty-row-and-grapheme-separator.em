# A row holding one empty field survives Csv.format, and a separator never
# matches inside a character.

print(Csv.format([[""]]).code_points())
print(Csv.parse(Csv.format([[""]])))
print(Csv.format([["a"], [""]]).code_points())
print(Csv.parse(Csv.format([["a"], [""]])))
print(Csv.format([["", ""], ["a"]]))
print(Csv.parse("ae\u{301}b", separator: "e")[0].map { field => field.code_points() })
print(Csv.parse("aeb", separator: "e"))
