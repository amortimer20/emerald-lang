# Mistake: misspelled field (line 6). Source: Kohn 2019 (The Error Behind the Message, Python novices) (AttributeError).
struct Pet {
    var name: String
}
var pet = Pet("Rex")
print(pet.nmae)
