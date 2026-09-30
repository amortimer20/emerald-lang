Tasks.run { tasks =>
    const pending = tasks.start { => input() }
    pending.cancel()
    try {
        pending.result()
    }
    catch error: CancelledError {
        print("input cancelled")
    }
}
print(input())
assert input_maybe() == nothing
