# Section 4.4: an optional chain is read-only, so assignment through `?.` is rejected
# at check time.
class User {
    var name: String = "Ava"
}

var user: User? = User()
user?.name = "Bo"
