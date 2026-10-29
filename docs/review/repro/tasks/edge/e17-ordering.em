# Only result/channel/yield waits: output order is promised to be the same every run.
const pipe: Channel[Int] = Channel(capacity: 1)
Tasks.run { tasks =>
    for name in ["a", "b", "c", "d"] {
        tasks.start { =>
            for i in 0..<3 {
                print("#{name}#{i}")
                Tasks.yield()
            }
        }
    }
    const producer = tasks.start { =>
        for i in 0..<5 {
            pipe.send(i)
            print("sent #{i}")
        }
        pipe.close()
    }
    print("main before")
    for item in pipe {
        print("got #{item}")
    }
    print("main after")
}
