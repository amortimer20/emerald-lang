Tasks.run { tasks =>
    const failed = tasks.start { =>
        raise RuntimeError("first failure")
    }
    tasks.start { =>
        tasks.start { =>
            try {
                Program.sleep(Duration(seconds: 60))
            }
            finally {
                print("late child cleanup")
            }
        }
        Tasks.yield()
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
