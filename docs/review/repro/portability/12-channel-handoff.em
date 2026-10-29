# 15.13 orders ready tasks but does not say whether a sender blocked on a full
# buffer has its message moved in when a receive frees space, or only when the
# sender next runs. This output depends on that.
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
