# Mistake: assigning a const field (line 6). Source: guide docs/language/objects-and-traits.md.
struct Book {
    const title: String
}
var b = Book("Dune")
b.title = "Emma"
