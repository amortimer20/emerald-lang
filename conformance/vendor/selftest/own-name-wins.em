# A name the program declares always wins (14.2); the library stays reachable
# qualified.
struct Selftest {
    var label: String
}

const mine = Selftest("mine")
print(mine.label)
print(Emerald.Selftest.add(1, 2))
