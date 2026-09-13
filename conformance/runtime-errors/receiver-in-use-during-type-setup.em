# A value a changing method holds is in use, not unset, even while its type is
# still being set up: reaching it reports the method, not a setup cycle.
struct Log {
    var lines: [String]

    func add(text: String) {
        self.lines.append(text)
        print(Board.log.lines.count)
    }
}

struct Board {
    var Board.log: Log = Log([])
    var Board.ready = Board.start()

    func Board.start(): Bool {
        Board.log.add("started")
        return true
    }
}

print(Board.ready)
