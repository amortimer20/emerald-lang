# exit(3) in the group block while a child's cleanup waits on a channel nobody feeds.
const never: Channel[Int] = Channel()
Tasks.run { tasks =>
    tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 30))
        }
        finally {
            print("cleanup waits")
            never.receive()
            print("cleanup continued")
        }
    }
    Tasks.yield()
    exit(3)
}
