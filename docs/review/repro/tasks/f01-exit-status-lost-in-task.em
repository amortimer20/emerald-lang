# Expected: process status 4 (15.2: "exit(code) uses the requested valid code").
# Actual: status 0.
Tasks.run { tasks =>
    tasks.start { => exit(4) }
}
print("unexpected continuation")
