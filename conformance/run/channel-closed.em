const buffered: Channel[Int] = Channel(capacity: 2)
buffered.send(value: 1)
buffered.send(2)
buffered.close()
buffered.close()
print(buffered.receive())
print(buffered.receive())
print(buffered.receive() == nothing)

const sending: Channel[Int] = Channel()
Tasks.run { tasks =>
    const producer = tasks.start { =>
        try {
            sending.send(3)
        }
        catch error: RuntimeError {
            return error.message
        }
        return "unexpected"
    }
    Tasks.yield()
    sending.close()
    print(producer.result())
}
const receiving: Channel[Int] = Channel()
Tasks.run { tasks =>
    const consumer = tasks.start { => receiving.receive() }
    Tasks.yield()
    receiving.close()
    print(consumer.result() == nothing)
}
const optional: Channel[Int?] = Channel(capacity: 2)
optional.send(nothing)
optional.send(7)
optional.close()
for value in optional {
    print(value)
}
