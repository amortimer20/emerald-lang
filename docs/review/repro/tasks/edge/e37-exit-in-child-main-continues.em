# exit() in a child: the group block may catch the cancellation and keep going.
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
print("after the group, after exit()")
