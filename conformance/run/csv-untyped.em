# CSV's untyped path keeps every cell as text. Parsing accepts RFC quoting,
# records use the first row as column names, and formatting quotes only where
# leaving text bare would change it.
const rows = Csv.parse("name,note\nAda,plain\n\"Hopper, Grace\",\"said \"\"hi\"\"\"")
print(rows.count)
print(rows[2][0])
print(rows[2][1])

const records = Emerald.Csv.parse_records("name;score\nAda;120\nGrace;95", separator: ";")
print(records.count)
print(records[0]["name"].or("missing"))
print(records[1]["score"].or("missing"))

print(Csv.format([["name", "note"], ["Ada", "plain"], ["Hopper, Grace", "said \"hi\""]]))
print(Csv.parse("left§right", separator: "§")[0][1])
print(Csv.parse("").count)
