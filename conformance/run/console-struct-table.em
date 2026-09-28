struct Score {
    const name: String
    const points: Int
    const ratio: Float?
    const _private: String = "hidden"
}

const scores = [Score("Ada", 120, 2.5), Score("Grace", 95, nothing), Score("Hopper", 88, 10.0)]
print(Console.table(scores))
const empty: List[Score] = []
print(Console.table(empty))

enum Choice { yes, no }
struct Answer { const choice: Choice }
assert Console.table([Answer(Choice.yes)]) == "┌────────────┐\n│ choice     │\n├────────────┤\n│ Choice.yes │\n└────────────┘"
