# Finding 07: Csv.format writes a row holding one empty field as an empty line, so the row is
# lost on the way back (and a document of only that row becomes no rows at all).
# Expected (15.11 / csv.md: "A field is quoted only when needed to preserve its meaning"):
#   format gives "\"\"" and "a\n\"\"", and both parse back to the original rows.
print(Csv.format([[""]]).code_points())
print(Csv.parse(Csv.format([[""]])))                 # expected [[""]], got []
print(Csv.parse(Csv.format([["a"], [""]])))          # expected [["a"], [""]], got [["a"]]
