Tasks.yield()
Tasks.run { tasks =>
    const first = tasks.start { =>
        for n in 1..3 {
            print("a#{n}")
            Tasks.yield()
        }
    }
    const second = tasks.start { =>
        for n in 1..3 {
            print("b#{n}")
            Tasks.yield()
        }
    }
    first.result()
    second.result()
}
