# Expected: "cleanup exits", then the program ends with status 7.
# Actual: the group's earlier failure wins: AssertionError "trigger" is reported, status 2.
Tasks.run { tasks =>
    tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 30))
        }
        finally {
            print("cleanup exits")
            exit(7)
        }
    }
    tasks.start { =>
        Tasks.yield()
        raise AssertionError("trigger")
    }
}
