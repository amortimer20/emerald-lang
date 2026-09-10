## A struct is a key because its hash can be derived from the fields == compares. Writing
## equals? takes that away: sameness is then whatever the method says, the derived hash
## would be a guess at agreeing with it, and a guess that is wrong loses values.
struct Tag with Equatable {
    var id: Int
    var note: String

    func equals?(other: Tag): Bool { return self.id == other.id }
}

var d: Dictionary<Tag, Int> = [:]
