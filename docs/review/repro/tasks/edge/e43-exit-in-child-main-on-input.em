# Run with a held-open stdin pipe. The group block is blocked in input(); a child calls exit(9).
Tasks.run { tasks =>
    tasks.start { =>
        Tasks.yield()
        exit(9)
    }
    print("main read #{input()}")
}
print("unexpected continuation")
