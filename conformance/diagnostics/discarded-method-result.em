# A built-in method that does not change its receiver only gives back its
# result, so calling it on its own line does nothing.
var name = "  Ava "
name.trim()
var scores = [3, 1, 2]
scores.sort()
scores.filter { score => score > 1 }
const fixed = [1, 2]
fixed.reverse()
name.split(",")
"shout".upper()

# Near misses: a method that changes its receiver, whatever it gives back, a
# result that is used, and a program's own method are all left alone.
scores.remove_last()
scores.sort!()
var ages: Dict[String, Int] = ["Ava": 12]
ages.remove("Ava")
var seen: Set[String] = []
seen.add("Ava")
print(name.trim())
name = name.trim()
scores.each { score => print(score) }

class Counter {
    var count: Int = 0
    func bump(): Int {
        self.count += 1
        return self.count
    }
}
const counter = Counter()
counter.bump()

# A call inside `try` may be made only to see whether it raises.
try {
    "12x".to_int()
}
catch error: Error {
    print(error.message)
}
