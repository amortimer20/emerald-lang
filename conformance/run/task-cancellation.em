Tasks.run { tasks =>
    const sleeper = tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 60))
            print("unexpected sleep completion")
        }
        catch error: RuntimeError {
            print("unexpected RuntimeError catch")
        }
        finally {
            print("sleep cleanup")
            Tasks.yield()
            print("cleanup complete")
        }
    }
    Tasks.yield()
    sleeper.cancel()
}
const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const receiver = tasks.start { =>
        try {
            numbers.receive()
        }
        finally {
            print("channel cleanup")
        }
    }
    Tasks.yield()
    receiver.cancel()
    try {
        receiver.result()
    }
    catch error: CancelledError {
        print(error.message)
    }
}
print("finished")
