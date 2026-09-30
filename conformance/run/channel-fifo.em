const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const first = tasks.start { => numbers.send(1) }
    const second = tasks.start { => numbers.send(2) }
    const third = tasks.start { => numbers.send(3) }
    Tasks.yield()
    print(numbers.receive())
    print(numbers.receive())
    print(numbers.receive())
    first.result()
    second.result()
    third.result()
}
Tasks.run { tasks =>
    const first = tasks.start { => numbers.receive() }
    const second = tasks.start { => numbers.receive() }
    const third = tasks.start { => numbers.receive() }
    Tasks.yield()
    numbers.send(4)
    numbers.send(5)
    numbers.send(6)
    print(first.result())
    print(second.result())
    print(third.result())
}
numbers.close()
