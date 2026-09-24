# User methods keep their meaning even when Random uses the same name.
struct Counter {
    var count: Int = 0
    func next(): Int {
        self.count += 1
        return self.count
    }
    func choose(selected: Bool): Int {
        return if selected then self.next() else -1
    }
    func shuffle!(amount: Int) {
        self.count += amount
    }
}
var counter = Counter()
print(counter.next(), counter.choose(true), counter.choose(false))
counter.shuffle!(10)
print(counter.count)

class Picker {
    func next(): String {
        return "base"
    }
    func choose(selected: Bool): String {
        return if selected then self.next() else "none"
    }
    func shuffle!(text: String): String {
        return text
    }
}
class Child extends Picker {
    @override
    func next(): String {
        return "child"
    }
}
const picker: Picker = Child()
print(picker.next(), picker.choose(true), picker.shuffle!("unchanged"))
const captured = picker.next
print(captured())
const absent: Picker? = nothing
print(absent?.next(), absent?.choose(true), absent?.shuffle!("skipped"))

# Genuine native Random operations and List.shuffle! still take their own paths.
const first = Random(seed: 42)
const second = Random(seed: 42)
print(first.next(1..100) == second.next(1..100))
print(first.choose(["a", "b"]) == second.choose(["a", "b"]))
var left = [1, 2, 3, 4]
var right = [1, 2, 3, 4]
first.shuffle!(left)
second.shuffle!(right)
print(left == right)
left.shuffle!()
print(left.sort())
