# The test-only library of docs/vendor-libraries-design-plan.md, decision 13. It
# exercises every kind of value a native module carries, and is the folder to
# copy for the next library (`vendor/_template`).

class SelftestError extends Error {
    constructor(message: String) {
        super(message)
    }
}

class Selftest {
    const _id: Int

    # Native: the sum of two integers.
    func Selftest._add(first: Int, second: Int): Int { return 0 }

    # Native: half of a float.
    func Selftest._halve(number: Float): Float { return 0.0 }

    # Native: the opposite of a boolean.
    func Selftest._invert(flag: Bool): Bool { return false }

    # Native: the text in upper case, for ASCII letters.
    func Selftest._shout(text: String): String { return "" }

    # Native: the bytes in the opposite order.
    func Selftest._reverse_bytes(data: Bytes): Bytes { return data }

    # Native: does nothing, and gives back nothing (the word is `ping` because `nothing` is a keyword).
    func Selftest._ping() {}

    # Native: always fails, with a message.
    func Selftest._always_fails(): Int { return 0 }

    # Native: how many counters are open.
    func Selftest._open_count(): Int { return 0 }

    ## The sum of two numbers.
    func Selftest.add(first: Int, second: Int): Int {
        return Emerald.Selftest._add(first, second)
    }

    ## Half of a number.
    func Selftest.halve(number: Float): Float {
        return Emerald.Selftest._halve(number)
    }

    ## The opposite of `flag`.
    func Selftest.invert(flag: Bool): Bool {
        return Emerald.Selftest._invert(flag)
    }

    ## The text in capital letters, for the letters A to Z.
    func Selftest.shout(text: String): String {
        return Emerald.Selftest._shout(text)
    }

    ## The bytes in the opposite order.
    func Selftest.reverse(data: Bytes): Bytes {
        return Emerald.Selftest._reverse_bytes(data)
    }

    ## Does nothing.
    func Selftest.ping() {
        Emerald.Selftest._ping()
    }

    ## Always raises a `SelftestError`.
    func Selftest.fails(): Int {
        return Emerald.Selftest._always_fails()
    }

    ## How many counters are open.
    func Selftest.open_count(): Int {
        return Emerald.Selftest._open_count()
    }

    ## A counter that starts at `start` and counts up.
    func Selftest.counter(start: Int = 0): Emerald.SelftestCounter {
        return Emerald.SelftestCounter.open(start)
    }
}

class SelftestCounter {
    const _id: Int

    # Native: opens a counter that starts at `start` and gives its handle.
    func SelftestCounter._open(start: Int): Int { return 0 }

    # Native: the counter's next number.
    func SelftestCounter._next(handle: Int): Int { return 0 }

    # Native: closes a counter.
    func SelftestCounter._close(handle: Int) {}

    # A private field cannot be set from outside the type (10.5), so the type
    # builds its own values, as `Stopwatch.start` does.
    func SelftestCounter.open(start: Int): Emerald.SelftestCounter {
        return Emerald.SelftestCounter(Emerald.SelftestCounter._open(start))
    }

    ## The next number.
    func next(): Int {
        return Emerald.SelftestCounter._next(self._id)
    }

    ## Closes the counter. A closed counter raises a `SelftestError` when used.
    func close() {
        Emerald.SelftestCounter._close(self._id)
    }
}
