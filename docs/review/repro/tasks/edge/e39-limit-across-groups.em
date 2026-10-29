# The 64-task cap is across the whole execution, not per group.
Tasks.run { outer =>
    var held: List[Task[Int?]] = []
    const gate: Channel[Int] = Channel()
    for i in 0..<40 {
        held.append(outer.start { => gate.receive() })
    }
    Tasks.yield()
    try {
        Tasks.run { inner =>
            for i in 0..<40 {
                inner.start { => 1 }
            }
        }
    }
    catch error: RuntimeError {
        print(error.message)
    }
    gate.close()
}
print("finished")
