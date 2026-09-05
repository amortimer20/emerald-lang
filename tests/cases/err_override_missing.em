## The fragile base class: a reset written without knowing Timer had one. Timer.run calls
## self.reset() and now reaches this, so ticks is never cleared — and both classes look
## correct in isolation, which is what makes it so hard to find by reading.
class Timer {
    var ticks: Int = 0

    func reset() { self.ticks = 0 }

    func run() {
        self.ticks = 5
        self.reset()
    }
}

class RaceTimer extends Timer {
    var laps: Int = 0

    func reset() { self.laps = 0 }
}
