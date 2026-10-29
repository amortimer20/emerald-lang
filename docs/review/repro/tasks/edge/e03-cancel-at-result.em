Tasks.run { tasks =>
    const slow = tasks.start { =>
        Program.sleep(Duration(seconds: 30))
        return 1
    }
    const waiter = tasks.start { =>
        try {
            return slow.result()
        }
        finally {
            print("waiter cleanup")
        }
    }
    Tasks.yield()
    waiter.cancel()
    try {
        waiter.result()
    }
    catch error: CancelledError {
        print("waiter: #{error.message}")
    }
    print("slow done? #{slow.done?()}")
    slow.cancel()
}
print("finished")
