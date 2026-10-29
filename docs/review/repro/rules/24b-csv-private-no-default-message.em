# Section 15.11: the same misleading message from Csv.decode for a private field with no default.
struct Score {
    const name: String
    const _source: String
}
const scores = Csv.decode("name\nAda", as: List[Score])
