# Mistake: TypeScript-style field without var (line 3). Source: carry-over from TypeScript/Kotlin.
class Dog {
    name: String
}
print(Dog("Rex").name)
