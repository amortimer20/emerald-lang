# Mistake: one ?. for a two-link chain (line 9). Source: guide docs/language/types-and-optionals.md.
struct Address {
    var city: String
}
struct User {
    var address: Address?
}
var user: User? = User(Address("Leeds"))
print(user?.address.city)
