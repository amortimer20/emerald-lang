# Mistake: extends on a struct (line 5). Source: carry-over from Java/C.
struct Animal {
    var name: String
}
struct Dog extends Animal {
}
