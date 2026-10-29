# exit(5) from the group's own block while a child sleeps.
Tasks.run { tasks =>
    tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 30))
        }
        finally {
            print("child cleanup")
        }
    }
    Tasks.yield()
    exit(5)
}
