# Section 15.8: Program.sleep takes one Duration, so its unit is never in doubt.
Program.sleep(5)
const nap = Program.sleep
Program.sleep(Duration(seconds: 1), 2)

# A built-in with private state points at how to get one.
const watch = Stopwatch()
const moment = Instant(1, 2)
