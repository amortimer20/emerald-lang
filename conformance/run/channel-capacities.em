func exchange(capacity: Int) {
    const numbers: Channel[Int] = Channel(capacity: capacity)
    Tasks.run { tasks =>
        tasks.start { =>
            for n in 1..5 {
                numbers.send(n)
            }
            numbers.close()
        }
        tasks.start { =>
            for n in numbers {
                print("#{capacity}:#{n}")
            }
        }
    }
}
exchange(0)
exchange(1)
exchange(3)
