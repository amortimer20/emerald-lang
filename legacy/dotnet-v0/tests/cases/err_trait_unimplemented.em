trait Swimmer {
    abstract func stamina(): Int
}
class Fish with Swimmer {
}
var f = Fish()
