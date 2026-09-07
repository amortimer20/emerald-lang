## Every field of a struct held as a key has to be a value that cannot change underneath
## it. A list field would let the hash drift after it was stored -- the same hazard a bare
## list key has, one level down, and refused in the same place.
struct Basket {
    var items: List<Int>
}

var counts: Dictionary<Basket, Int> = [:]
