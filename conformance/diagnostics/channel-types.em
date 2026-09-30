const numbers: Channel[Int] = Channel()
numbers.send("wrong")
numbers.send()
numbers.receive(1)
numbers.unknown()
const wrong: Channel[Float] = numbers
const missing = Channel()
const capacity: Channel[Int] = Channel(capacity: "wrong")
