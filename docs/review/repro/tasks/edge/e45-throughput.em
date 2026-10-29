# 100,000 messages through a rendezvous channel.
const numbers: Channel[Int] = Channel()
const total = Tasks.run { tasks =>
    tasks.start { =>
        for i in 0..<100000 {
            numbers.send(i)
        }
        numbers.close()
    }
    var sum = 0
    for n in numbers {
        sum += n
    }
    return sum
}
print(total)
