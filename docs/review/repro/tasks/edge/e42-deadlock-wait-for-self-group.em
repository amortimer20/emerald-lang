# A child waits on the result of a task that waits on a channel only the group block feeds,
# while the group block waits on the child: a three-party cycle.
const feed: Channel[Int] = Channel()
Tasks.run { tasks =>
    const consumer = tasks.start { => feed.receive() }
    const middle = tasks.start { => consumer.result() }
    middle.result()
    feed.send(1)
}
