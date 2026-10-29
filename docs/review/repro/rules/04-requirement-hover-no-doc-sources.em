# Section 3.2: when several satisfied requirements give different text, each source
# is presented rather than one chosen.
trait Walker {
    ## Moves on legs.
    func move()
}

trait Swimmer {
    ## Moves through water.
    func move()
}

struct Duck with Walker, Swimmer {
    @override
    func move() {
        print("waddle")
    }
}

var duck = Duck()
duck.mo/*cursor*/ve()
