struct Item {
    var numbers: List[Int]
}
class Shared {
    var number: Int = 0
}
const lists: Channel[List[Int]] = Channel(capacity: 1)
const items: Channel[Item] = Channel(capacity: 1)
const references: Channel[Shared] = Channel(capacity: 1)
const floats: Channel[Float] = Emerald.Channel(capacity: 1)
assert(floats.type_name == "Channel[Float]")
Tasks.run { tasks =>
    const producer = tasks.start { =>
        var list = [1, 2]
        lists.send(list)
        list.append(3)
        var item = Item([4])
        items.send(item)
        item.numbers.append(5)
        const reference = Shared()
        references.send(reference)
        reference.number = 9
        floats.send(2)
    }
    producer.result()
    print(lists.receive().or([]))
    print(items.receive().or(Item([])).numbers)
    print(references.receive().or(Shared()).number)
    print(floats.receive().or(0).to_string())
}
