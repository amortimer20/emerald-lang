# Typed CSV encoding writes a declaration-order header and shares decoding's
# scalar vocabulary. A round trip keeps ordinary values, defaults, and empty
# optional cells intact.
enum Team { red, blue }

struct Score {
    const name: String
    const points: Int
    const ratio: Float
    const active: Bool
    const team: Team
    const played_on: Date
    const note: String?
    const _balance: Int = 100
}

const scores = [
    Score("Ada", 120, 2.0, true, Team.red, Date(2026, 9, 28), nothing),
    Score("Hopper, Grace", 88, 1.5, false, Team.blue, Date(2026, 10, 1), "said \"hi\""),
]
const text = Csv.encode(scores)
print(text)

const round_trip = Csv.decode(text, as: List[Score])
print(round_trip == scores)
print(round_trip[1].note)

# The separator is named and works independently of the records argument.
print(Csv.encode(separator: ";", records: [Score("A", 1, 0.0, true, Team.red, Date(2026, 1, 2), "x")]))

# An empty typed list still has its header, which a later decoder can use.
const none: List[Score] = []
print(Csv.encode(none))
print(Emerald.Csv.encode(none))

# Writer-side separator failures stay the same catchable CsvError as parsing.
try {
    Csv.encode(scores, separator: ";;")
}
catch error: CsvError {
    print(error.message)
    print(error.line.or(-1))
}
