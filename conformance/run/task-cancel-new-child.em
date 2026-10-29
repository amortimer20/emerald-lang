Tasks.run { tasks =>
    tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 60))
        }
        finally {
            const late = tasks.start { => print("unexpected: late child ran") }
            try {
                late.result()
            }
            catch error: CancelledError {
                print("late child: #{error.message}")
            }
        }
    }
    const failed = tasks.start { =>
        Tasks.yield()
        raise RuntimeError("first failure")
    }
    try {
        failed.result()
    }
    catch error: RuntimeError {
        print(error.message)
    }
}
Tasks.run { tasks =>
    const parent = tasks.start { =>
        try {
            Tasks.run { inner =>
                inner.start { =>
                    try {
                        Program.sleep(Duration(seconds: 60))
                    }
                    finally {
                        print("nested child cleanup")
                    }
                }
            }
        }
        finally {
            print("parent cleanup")
        }
    }
    Tasks.yield()
    parent.cancel()
}
print("finished")
