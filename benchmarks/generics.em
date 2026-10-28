# Generic types: a stack and a queue of your own, used heavily.

class Stack[Item] {
    var _items: List[Item] = []

    func push(item: Item) {
        self._items.append(item)
    }

    func pop(): Item? {
        if self._items.empty?() {
            return nothing
        }
        return self._items.remove_last()
    }

    func size(): Int {
        return self._items.count
    }
}

const stack: Stack[Int] = Stack()
var total = 0
for round in 0..<400 {
    for n in 0..<500 {
        stack.push(n + round)
    }
    while stack.size() > 0 {
        total += stack.pop().or(0)
    }
}
print(total)
