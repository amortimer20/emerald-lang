# Section 14.1: code after a `while true` with no `break` never runs. The
# warning points at the loop, which is the mistake, and says why.
var tries = 0
while true {
    tries += 1
}
print(tries)

func first_even(numbers: List[Int]): Int {
    while true {
        for number in numbers {
            return number if number % 2 == 0
        }
        raise Error("no even number")
    }
    print("searched")
}

# A `break` inside a nested loop leaves only that loop.
func spin() {
    while true {
        for _ in 1..3 {
            break
        }
    }
    print("done")
}

# Near misses: a loop with its own `break`, and a server-style loop with
# nothing after it, are intended, so neither warns.
var count = 0
while true {
    count += 1
    break if count == 3
}
print(count)

func serve() {
    while true {
        print("waiting")
    }
}
