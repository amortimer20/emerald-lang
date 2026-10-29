# Section 15.11: CSV never reads a private field; it takes its default.
struct Score {
    const name: String
    const _source: String = "csv"

    func describe(): String {
        return "#{self.name} from #{self._source}"
    }
}

const scores = Csv.decode("name,_source\nAda,file", as: List[Score])
print(scores.map { score => score.describe() })
print(Csv.encode(scores))
