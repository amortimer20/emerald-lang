# exit() in a child is not an error (15.2): the group block cannot catch it as a
# cancellation, only `finally` blocks run, and the program ends with its status.
Tasks.run { tasks =>
    tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 30))
        }
        catch error: CancelledError {
            print("unexpected: sibling caught #{error.message}")
        }
        finally {
            print("sibling cleanup")
        }
    }
    tasks.start { =>
        Tasks.yield()
        exit(6)
    }
    try {
        Program.sleep(Duration(seconds: 30))
    }
    catch error: Error {
        print("unexpected: main caught #{error.message}")
    }
    finally {
        print("main cleanup")
    }
    print("unexpected: main still running after exit()")
}
print("unexpected continuation")
