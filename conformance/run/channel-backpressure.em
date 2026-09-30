class Progress {
    var finished: Bool = false
}
const progress = Progress()
const numbers: Channel[Int] = Channel(capacity: 1)
Tasks.run { tasks =>
    const producer = tasks.start { =>
        numbers.send(1)
        numbers.send(2)
        progress.finished = true
    }
    Tasks.yield()
    assert(not progress.finished)
    print(numbers.receive())
    producer.result()
    assert(progress.finished)
    print(numbers.receive())
}
const stream: Channel[Int] = Channel(capacity: 3)
Tasks.run { tasks =>
    tasks.start { =>
        for n in 1..10000 {
            stream.send(n)
        }
        stream.close()
    }
    const total = tasks.start { =>
        var sum = 0
        for n in stream {
            sum += n
        }
        return sum
    }
    print(total.result())
}
