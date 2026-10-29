Tasks.run { tasks =>
    const quick = tasks.start { => 5 }
    print(quick.result())
    quick.cancel()
    quick.cancel()
    print(quick.done?())
    print(quick.result())
    print(quick.wait(Duration()))
    const failing = tasks.start { =>
        raise AssertionError("boom")
    }
    try {
        failing.result()
    }
    catch error: AssertionError {
        print("caught #{error.message}")
    }
    failing.cancel()
    try {
        failing.result()
    }
    catch error: AssertionError {
        print("still #{error.message}")
    }
}
print("finished")
