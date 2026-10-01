func forever(n: Int): Int {
    return forever(n + 1)
}

try {
    print(forever(0))
}
catch error: RecursionError {
    print("main: #{error.message}")
}
catch error: RuntimeError {
    print("wrong main error type")
}
finally {
    print("main cleanup")
}

try {
    Tasks.run { tasks =>
        const task: Task[Int] = tasks.start { => forever(0) }
        print(task.result())
    }
}
catch error: RecursionError {
    print("task: #{error.message}")
}
catch error: RuntimeError {
    print("wrong task error type")
}
finally {
    print("task cleanup")
}

try {
    print(forever(0))
}
catch error: RuntimeError {
    assert error is RecursionError
    print("RuntimeError still catches recursion")
}
