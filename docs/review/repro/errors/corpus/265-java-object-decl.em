# Mistake: Java object declaration (line 5). Source: carry-over from Java/C.
class Dog {
    var name: String
}
Dog rex = Dog("Rex")
print(rex.name)
