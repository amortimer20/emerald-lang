# Escaped handles own results; later groups and collection must not invalidate them.
const saved = Tasks.run { tasks =>
    return tasks.start { => [1, 2, 3] }
}
const callback = Tasks.run { tasks =>
    const job = tasks.start { =>
        const action = { => 17 }
        return action
    }
    return job
}
for i in 0..<200 {
    const result = Tasks.run { tasks =>
        return tasks.start { => [i] }.result()
    }
    assert(result[0] == i)
}
assert(saved.done?())
assert(saved.result() == [1, 2, 3])
assert(callback.result()() == 17)
assert(saved.result() == [1, 2, 3])
saved.cancel()
const failure = Tasks.run { tasks =>
    const failed = tasks.start { =>
        raise RuntimeError("remembered")
    }
    try {
        failed.result()
    }
    catch error: RuntimeError {
        assert(error.message == "remembered")
    }
    return failed
}
try {
    failure.result()
}
catch error: RuntimeError {
    print(error.message)
}
print(saved.result())
