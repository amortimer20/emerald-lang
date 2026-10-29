Tasks.run { tasks =>
    const slow = tasks.start { =>
        Program.sleep(Duration(seconds: 30))
        return 1
    }
    const waiter = tasks.start { =>
        try {
            return slow.wait(timeout: Duration(seconds: 20))
        }
        finally {
            print("waiter cleanup")
        }
    }
    Tasks.yield()
    waiter.cancel()
    try {
        print(waiter.result())
    }
    catch error: CancelledError {
        print("waiter: #{error.message}")
    }
    slow.cancel()
}
print("finished")
