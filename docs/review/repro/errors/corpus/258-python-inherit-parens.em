# Mistake: Python class Dog(Animal) (line 5). Source: carry-over from Python.
class Animal {
    var name: String
}
class Dog(Animal) {
}
print(Dog("Rex").name)
