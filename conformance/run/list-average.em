# Section 8.6's numeric average is Float and an empty List has no answer.

const whole_numbers = [1, 2]
const decimal_numbers = [1.5, 2.5]
const empty: [Int] = []

print(whole_numbers.average().or(0.0), decimal_numbers.average().or(0.0), empty.average())
print([Float.infinity, 1.0].average(), [Float.nan, 1.0].average().or(0.0).nan?())
