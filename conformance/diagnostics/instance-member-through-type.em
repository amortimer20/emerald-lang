# Section 10.4: an instance member belongs to each value, so it is not reached
# through the type.
struct Player {
    var name: String

    func greet() {
        print("hi, #{self.name}")
    }
}

print(Player.name)
Player.greet()
print(Player.count)
