# Section 8.6's keyed extrema return their List items, using the first tied key.

const words = ["pear", "fig", "plum", "kiwi"]
const empty: [String] = []
print(words.min_by { word => word.count }.or(""), words.max_by { word => word.count }.or(""), empty.min_by { word => word.count })
print(words.min_by { word => word }.or(""), words.max_by { word => word }.or(""))

struct Player {
    const name: String
    const score: Float
}

const players = [Player("Ava", 8.5), Player("Bea", 9.0), Player("Cal", 9.0)]
print(players.min_by { player => player.score }.or(Player("", 0.0)).name)
print(players.max_by { player => player.score }.or(Player("", 0.0)).name)

struct Rank with Ordered {
    const value: Int

    @override
    func compare(other: Self): Int {
        return self.value - other.value
    }
}

const labels = ["red", "blue", "green"]
print(labels.min_by { label => Rank(label.count) }.or(""), labels.max_by { label => Rank(label.count) }.or(""))
