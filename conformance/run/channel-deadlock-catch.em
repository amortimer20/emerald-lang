const numbers: Channel[Int] = Channel()
try {
    Tasks.run { tasks =>
        tasks.start { => numbers.receive() }
        tasks.start { => 9 }
    }
}
catch error: DeadlockError {
    print(error.message)
}
numbers.close()
print(numbers.receive() == nothing)
