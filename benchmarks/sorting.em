# Sorting: a shuffled list of numbers, then of records by a key.

struct Player {
    const name: String
    const score: Int
}

const generator = Random(7)
var numbers = (0..<400000).to_list()
generator.shuffle!(numbers)
const sorted = numbers.sort()
print(sorted[0], sorted[sorted.count - 1])

var players: List[Player] = []
for index in 0..<150000 {
    players.append(Player("player #{index}", generator.next(0..1000)))
}
const ranked = players.sort_by { player => player.score }
print(ranked[0].score, ranked[ranked.count - 1].score)
