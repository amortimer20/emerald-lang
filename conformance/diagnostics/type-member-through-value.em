# Section 10.4: "Call sites make the ownership visible." A type-level member is
# reached through its type, never through a value.
struct Player {
    var name: String
    var Player.count = 0

    func Player.named(name: String): Player {
        return Player(name)
    }

    func describe(): String {
        return "#{self.name} of #{self.count}"
    }
}

const ada = Player("Ada")
print(ada.count)
ada.named("Grace")
