# Mistake: assigning through ?. (line 6). Source: guide docs/language/types-and-optionals.md.
struct User {
    var name: String
}
var user: User? = User("Ava")
user?.name = "Bo"
