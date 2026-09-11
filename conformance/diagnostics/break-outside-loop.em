# A function body is not inside the loop that calls it, so `break` cannot
# reach one.

func stop() {
    break
}

for number in 1..3 {
    stop()
}
