# Several tasks wait on one result, and on one channel; they resume in the order they waited.
const go: Channel[Int] = Channel()
const fan: Channel[Int] = Channel()
Tasks.run { tasks =>
    const target = tasks.start { =>
        go.receive()
        return 1
    }
    for name in ["e", "d", "c", "b", "a"] {
        tasks.start { =>
            target.result()
            print("result waiter #{name}")
        }
    }
    for name in ["v", "w", "x", "y", "z"] {
        tasks.start { =>
            print("receiver #{name} got #{fan.receive().or(-1)}")
        }
    }
    Tasks.yield()
    go.send(0)
    for i in 0..<5 {
        fan.send(i)
    }
}
