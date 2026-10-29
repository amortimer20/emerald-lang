const numbers: Channel[Int] = Channel(capacity: 2)
Tasks.run { tasks =>
    numbers.send(1)
    numbers.send(2)
    var blocked: List[Task[String]] = []
    for n in [3, 4] {
        blocked.append(tasks.start { =>
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
    for task in blocked {
        print(task.result())
    }
    for item in numbers {
        print(item)
    }
}
print("finished")
