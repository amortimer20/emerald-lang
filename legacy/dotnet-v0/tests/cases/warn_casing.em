## Casing is a warning, not an error — renaming is a semantic change, and the program
## still runs.
var playerName = "ana"
const maxScore = 100

class player_stats {
    var Health: Int
    constructor(Health: Int) { self.Health = Health }
}

func GetScore(playerId: Int): Int { return playerId * 2 }

print(playerName)
print(maxScore)
print(GetScore(3))
print(player_stats(5).Health)
