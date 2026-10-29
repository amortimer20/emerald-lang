# The parent is parked in its inner group's implicit join when a sibling cancels it.
Tasks.run { outer =>
    const parent = outer.start { =>
        try {
            Tasks.run { inner =>
                inner.start { =>
                    try {
                        Program.sleep(Duration(seconds: 30))
                    }
                    finally {
                        print("inner child cleanup")
                    }
                }
            }
            print("unexpected: inner group joined normally")
        }
        finally {
            print("parent cleanup")
        }
    }
    outer.start { =>
        Tasks.yield()
        Tasks.yield()
        parent.cancel()
    }
    try {
        parent.result()
    }
    catch error: CancelledError {
        print("parent: #{error.message}")
    }
}
print("finished")
