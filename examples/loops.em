# The prime numbers below 50, then how many steps the Collatz sequence takes to
# fall from 27 to 1.

for candidate in 2..<50 {
    var prime = true
    for divisor in 2..<candidate {
        break if divisor * divisor > candidate
        if candidate % divisor == 0 {
            prime = false
            break
        }
    }
    print(candidate) if prime
}

func collatz_steps(start: Int): Int {
    var number = start
    var steps = 0
    while number != 1 {
        if number % 2 == 0 {
            number = number // 2
        }
        else {
            number = 3 * number + 1
        }
        steps += 1
    }
    return steps
}

print(collatz_steps(27))
