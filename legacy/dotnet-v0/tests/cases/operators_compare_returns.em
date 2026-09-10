class Card with Ordered {
    var rank: Int
    constructor(rank: Int) { self.rank = rank }
    func compare(other: Card): String { return "hm" }
}

print("#{Card(1) < Card(2)}")
