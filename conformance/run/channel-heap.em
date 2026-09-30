const jobs: Channel[func(): Int] = Channel(capacity: 3)
Tasks.run { tasks =>
    tasks.start { =>
        for n in 1..1000 {
            var again = { => n }
            const job = { => again() }
            jobs.send(job)
        }
        jobs.close()
    }
    const consumer = tasks.start { =>
        var sum = 0
        for job in jobs {
            sum += job()
        }
        return sum
    }
    print(consumer.result())
}
