# Section 15.13: when a receive frees buffer space, the longest-waiting sender's message is
# committed into the buffer at once and that sender becomes ready.
Tasks.run { tasks =>
    const channel: Channel[Int] = Channel(capacity: 1)
    tasks.start { =>
        for i in 0..<3 {
            print("send", i)
            channel.send(i)
        }
        channel.close()
    }
    tasks.start { =>
        for value in channel {
            print("got", value)
        }
    }
}
