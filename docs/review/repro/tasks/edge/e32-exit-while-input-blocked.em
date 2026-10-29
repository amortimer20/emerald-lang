# Run with a held-open stdin pipe. A task is blocked in input(); main exits.
# Program exit must not join the in-flight reader.
Tasks.run { tasks =>
    tasks.start { =>
        try {
            print("got #{input()}")
        }
        finally {
            print("reader cleanup")
        }
    }
    Tasks.yield()
    exit(2)
}
