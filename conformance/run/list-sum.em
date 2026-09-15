# Section 8.6's first aggregation: numeric Lists have a clear additive identity.

const whole_numbers = [1, -2, 3]
const no_whole_numbers: [Int] = []
const decimal_numbers = [1.5, 2, -0.5]
const no_decimal_numbers: [Float] = []

print(whole_numbers.sum(), no_whole_numbers.sum())
print(decimal_numbers.sum(), no_decimal_numbers.sum())
print([Float.infinity, 1.0].sum(), [Float.nan, 1.0].sum().nan?())
