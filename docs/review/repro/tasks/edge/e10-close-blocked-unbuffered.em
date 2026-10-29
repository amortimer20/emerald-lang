const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    var senders: List[Task[String]] = []
    for n in [1, 2, 3] {
        senders.append(tasks.start { =>
            var outcome = "sent #{n}"
            try {
                numbers.send(n)
            }
            catch error: RuntimeError {
                outcome = "send #{n}: #{error.message}"
            }
            return outcome
        })
    }
    Tasks.yield()
    print(numbers.receive())
    numbers.close()
    numbers.close()
    for task in senders {
        print(task.result())
    }
    print(numbers.receive())
}
const words: Channel[String] = Channel()
Tasks.run { tasks =>
    var receivers: List[Task[String?]] = []
    for n in [1, 2, 3] {
        receivers.append(tasks.start { => words.receive() })
    }
    Tasks.yield()
    words.send("one")
    words.close()
    for task in receivers {
        print(task.result())
    }
}
print("finished")
