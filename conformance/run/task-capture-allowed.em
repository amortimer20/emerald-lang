var module_count = 4

func read_module(): Int {
    return module_count
}

Tasks.run { tasks =>
    const captured = 3
    const local = tasks.start { =>
        var own_count = 2
        own_count += captured
        return own_count
    }
    const through_function = tasks.start { => read_module() }
    print(local.result())
    print(through_function.result())
}
