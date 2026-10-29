# The only other task waits forever on a channel. wait(timeout:) is a timer, not a deadlock.
const never: Channel[Int] = Channel()
Tasks.run { tasks =>
    const stuck = tasks.start { => never.receive() }
    print(stuck.wait(timeout: Duration(milliseconds: 20)))
    never.close()
    print(stuck.result())
}
