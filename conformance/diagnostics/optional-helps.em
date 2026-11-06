var name: String = nothing
var found = [1, 2, 3].find { n => n > 1 }
if found {
    print("found it")
}
struct Address {
    var city: String
}
struct User {
    var address: Address?
}
var user: User? = User(Address("Leeds"))
print(user?.address.city)
var n = "5".to_int_maybe()
if n > 3 {
    print("big")
}
func square(n: Int): Int {
    return n * n
}
print(square(n))
