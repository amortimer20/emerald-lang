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
struct Message {
    const value: Int?
}
const messages: Channel[Message] = Channel(capacity: 2)
messages.send(Message(nothing))
messages.send(Message(7))
messages.close()
for message in messages {
    print(message.value)
}
