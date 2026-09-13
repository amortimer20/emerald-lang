const _limit = 2

struct Board {
    var entries: [Int]

    # Reads a value private to this file, from wherever it is called.
    func record(score: Int) {
        self.entries.append(score)
        if self.entries.count > _limit {
            self.entries.remove_at(0)
        }
    }

    func best(): Int {
        var top = 0
        for entry in self.entries {
            top = entry if entry > top
        }
        return top
    }
}

var board = Board([9])
