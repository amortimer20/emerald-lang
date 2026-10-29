# A task raises while two siblings and the group block wait on it.
try {
    Tasks.run { tasks =>
        const failing = tasks.start { =>
            Tasks.yield()
            raise AssertionError("failed child")
        }
        const a = tasks.start { =>
            var outcome = "a got a value"
            try {
                failing.result()
            }
            catch error: AssertionError {
                outcome = "a observed: #{error.message}"
            }
            return outcome
        }
        const b = tasks.start { =>
            try {
                failing.result()
            }
            finally {
                print("b cleanup")
            }
        }
        print("a: #{a.result()}")
    }
}
catch error: AssertionError {
    print("group raised: #{error.message}")
}
catch error: CancelledError {
    print("group raised CancelledError: #{error.message}")
}
print("finished")
