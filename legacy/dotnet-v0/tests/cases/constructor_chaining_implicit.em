## A base constructor that needs nothing is called anyway, without being written. The
## simple hierarchy stays quiet, and the base still gets to run.
class Timer {
    var ticks: Int = 0
    constructor() { self.ticks = 99 }
}

class RaceTimer extends Timer {
    var laps: Int
    constructor(laps: Int) { self.laps = laps }
}

var r = RaceTimer(3)
print(r.laps)
print(r.ticks)
