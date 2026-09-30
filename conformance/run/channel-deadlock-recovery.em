const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const consumer = tasks.start { =>
        try {
            return numbers.receive().or(0)
        }
        catch error: DeadlockError {
            return -1
        }
    }
    try {
        numbers.receive()
    }
    catch error: DeadlockError {
        try {
            numbers.send(7)
            assert false, "a readied deadlock participant must not accept a message"
        }
        catch second: DeadlockError {
            print("no receiver")
        }
    }
    numbers.close()
    print(consumer.result())
}
