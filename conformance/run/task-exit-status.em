# A child's exit(code) ends the whole program with that status (15.2, 15.13).
Tasks.run { tasks =>
    tasks.start { => exit(4) }
}
print("unexpected continuation")
