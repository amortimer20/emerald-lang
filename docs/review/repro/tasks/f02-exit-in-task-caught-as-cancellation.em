# Expected: the program ends at exit(6) with status 6, after cleanup; nothing more prints.
# Actual: the group block catches CancelledError, keeps running, prints both lines; status 0.
Tasks.run { tasks =>
    tasks.start { =>
        Tasks.yield()
        exit(6)
    }
    try {
        Program.sleep(Duration(seconds: 30))
    }
    catch error: CancelledError {
        print("main caught cancellation after exit()")
    }
    print("main still running after exit()")
}
