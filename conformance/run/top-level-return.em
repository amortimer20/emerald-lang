# Section 14.1: a bare top-level `return` ends the program successfully,
# right where it runs, after any pending `finally` blocks — the same
# unwinding a function's own `return` already does.
print("start")

var stop = true
try {
    if stop {
        print("before return")
        return
    }
    print("not reached")
} finally {
    print("cleanup always runs")
}

print("after the try")
