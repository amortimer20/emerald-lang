Tasks.run { tasks =>
    for i in 0..<65 {
        tasks.start { => i }
    }
}
