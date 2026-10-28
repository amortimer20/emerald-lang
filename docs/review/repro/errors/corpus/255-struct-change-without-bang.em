# Mistake: struct method changing self (line 9). Source: guide docs/language/objects-and-traits.md.
struct Counter {
    var count: Int
    func increment() {
        self.count += 1
    }
}
const c = Counter(0)
c.increment()
print(c)
