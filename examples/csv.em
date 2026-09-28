# CSV: read records from spreadsheet-style text, then write them back.
# Run it with `emerald run examples/csv.em`.

struct Score {
    const name: String
    const points: Int
    const team: String? = nothing
}

const csv_text = "name,points,team\nAda,120,red\nGrace,95,\n\"Hopper, Grace\",88,blue"
const scores = Csv.decode(csv_text, as: List[Score])
for score in scores {
    print("#{score.name}: #{score.points}")
}

# Csv.encode produces a header and quotes only where the CSV format needs it.
print(Csv.encode(scores))

# When the columns are not known until runtime, read string records instead.
const survey = Csv.parse_records("name,answer\nAda,yes\nGrace,no")
print(survey[0]["name"], survey[0]["answer"])
