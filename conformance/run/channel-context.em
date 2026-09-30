func make_channel(): Channel[Int] {
    return Channel(capacity: 1)
}
func consume(channel: Channel[Int]): Int {
    channel.send(6)
    channel.close()
    return channel.receive().or(0)
}
const channels: List[Channel[Int]] = [Channel(capacity: 1), make_channel()]
print(consume(channels[0]))
print(consume(channels[1]))
var optional: Channel[Int]? = Channel(capacity: 1)
if optional != nothing {
    print(consume(optional))
}
print(consume(Channel(capacity: 1)))
