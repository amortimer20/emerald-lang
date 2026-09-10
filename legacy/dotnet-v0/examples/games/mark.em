# How one letter of a guess turned out. A module file's declarations are the project's,
# so the enum is reached as Mark from anywhere — the file name only groups it.
#
# rank and better_than? were statics on Wordle until an enum could hold a method. They
# are facts about a Mark, and they belong on one.

enum Mark {
    HIT, PRESENT, MISS

    # How much this one is worth as news. Green outranks yellow outranks grey.
    func rank(): Int {
        return if self == Mark.HIT then 2 else if self == Mark.PRESENT then 1 else 0
    }

    func better_than?(other: Mark): Bool {
        return self.rank() > other.rank()
    }
}
