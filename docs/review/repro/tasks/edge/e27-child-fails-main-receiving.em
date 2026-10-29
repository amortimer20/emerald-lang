# The group block waits on a channel (not on the failing child's result).
const never: Channel[Int] = Channel()
try {
    Tasks.run { tasks =>
        tasks.start { =>
            Program.sleep(Duration(milliseconds: 5))
            raise AssertionError("child failed")
        }
        try {
            never.receive()
        }
        finally {
            print("block cleanup")
        }
    }
}
catch error: AssertionError {
    print("caught #{error.message}")
}
print("finished")
