const messages: Channel[Int] = Channel()
try {
    Tasks.run { tasks =>
        tasks.start { =>
            try {
                messages.receive()
            }
            finally {
                print("child cleanup")
            }
        }
        tasks.start { =>
            raise RuntimeError("first failure")
        }
        try {
            messages.receive()
        }
        catch error: RuntimeError {
            print("unexpected RuntimeError catch")
        }
        finally {
            print("group cleanup")
        }
    }
}
catch error: RuntimeError {
    print(error.message)
}
print("finished")
