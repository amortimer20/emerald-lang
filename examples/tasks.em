## Try it: emerald run examples/tasks.em

# Print results in the order wanted, not from inside the tasks.
Tasks.run { tasks =>
    const first = tasks.start { =>
        Tasks.yield()
        return 10
    }
    const second = tasks.start { => 20 }
    print(first.result(), second.result())
}

# A producer and consumer pass values through a small buffer.
const numbers: Channel[Int] = Channel(capacity: 2)
Tasks.run { tasks =>
    tasks.start { =>
        for number in 1..3 {
            numbers.send(number)
        }
        numbers.close()
    }
    const total = tasks.start { =>
        var sum = 0
        for number in numbers {
            sum += number
        }
        return sum
    }
    print("total: #{total.result()}")
}

# Cancellation runs cleanup, without waiting for the sleep to finish.
Tasks.run { tasks =>
    const slow = tasks.start { =>
        try {
            Program.sleep(Duration(milliseconds: 20))
        }
        finally {
            print("cleaning up")
        }
    }
    Tasks.yield()
    slow.cancel()
}
