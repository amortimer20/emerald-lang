# exit(4) from a lone child, with no other task alive.
Tasks.run { tasks =>
    tasks.start { => exit(4) }
}
print("unexpected continuation")
