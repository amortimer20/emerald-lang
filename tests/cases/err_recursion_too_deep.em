## Runaway recursion is a message, not a crash.
##
## A .NET StackOverflowException cannot be caught: the process is killed and the runtime
## prints its own frames. So the commonest mistake in the week a class meets recursion --
## a function with no base case -- produced a wall of "at Emerald.Interpreter.EvaluateCall"
## and no message at all. §3.6 promises that no .NET stack trace ever reaches the reader,
## and this was the loudest available way to break it.
##
## Two halves. The interpreter counts how deep it is and stops at a number, so the answer
## is the same on every machine -- a limit that depends on how much stack is left would
## fail here and work there, which is the one thing a beginner cannot debug. And the
## program runs on a thread with room for that many, so the counter is always what fires.
func forever(n: Int): Int {
    return 1 + forever(n + 1)
}

print(forever(1))
