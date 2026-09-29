Tasks.run { tasks =>
    const parent = tasks.start { =>
        const child = tasks.start { => 4 }
        return child.result() + 1
    }
    print(parent.result())
}
