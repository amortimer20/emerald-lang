# No task exists at all: a receive and a send on the root program can never progress.
const numbers: Channel[Int] = Channel()
try {
    numbers.receive()
}
catch error: DeadlockError {
    print("receive: #{error.message}")
}
try {
    numbers.send(1)
}
catch error: DeadlockError {
    print("send: #{error.message}")
}
const buffered: Channel[Int] = Channel(capacity: 1)
buffered.send(1)
print(buffered.receive())
try {
    buffered.receive()
}
catch error: DeadlockError {
    print("buffered receive: #{error.message}")
}
print("finished")
