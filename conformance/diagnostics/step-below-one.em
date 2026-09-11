# Section 6.4: a step is a distance, so it is at least 1. The direction comes
# from the range, never from the sign of the step.

for number in 10.down_to(0).step(-2) {
    print(number)
}
