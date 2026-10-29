# Cancelling a parent cancels and joins its nested children before the parent's cleanup ends.
Tasks.run { outer =>
    const parent = outer.start { =>
        try {
            Tasks.run { inner =>
                for i in 0..<3 {
                    inner.start { =>
                        try {
                            Program.sleep(Duration(seconds: 30))
                        }
                        finally {
                            print("child #{i} cleanup")
                        }
                    }
                }
                Program.sleep(Duration(seconds: 30))
            }
        }
        finally {
            print("parent cleanup")
        }
    }
    Tasks.yield()
    Tasks.yield()
    parent.cancel()
    try {
        parent.result()
    }
    catch error: CancelledError {
        print("parent: #{error.message}")
    }
}
print("finished")
