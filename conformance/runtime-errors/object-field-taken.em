# Section 4.3 and 10.1: a changing method called on a struct in an object's
# field has that field to itself while it runs, as it would a variable, so a
# block that writes the field meanwhile is an error rather than a change the
# call silently overwrites.

struct Tally {
    var count: Int

    func add_twice(between: func()) {
        self.count += 1
        between()
        self.count += 1
    }
}

class Scoreboard {
    var home: Tally = Tally(0)
    var away: Tally = Tally(0)
}

const board = Scoreboard()
# Other fields of the object are free to use.
board.home.add_twice { => board.away.count += 5 }
print(board.home.count, board.away.count)
board.home.add_twice { => board.home.count = 100 }
