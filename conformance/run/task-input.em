Tasks.run { tasks =>
    const first = tasks.start { => input("first? ") }
    const second = tasks.start { => input("second? ") }
    print(first.result())
    print(second.result())
    const end = tasks.start { => input_maybe() }
    print(end.result() == nothing)
    const missing = tasks.start { => input() }
    try {
        missing.result()
    }
    catch error: InputError {
        print("input ended")
    }
}
