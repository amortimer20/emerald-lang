# Section 5.3: `%` with a Float operand returns Float; a NaN remainder operand, or an
# infinite dividend, produces NaN. (A negative or infinite divisor is a finding:
# docs/review/repro/rules/06 and 07.)
print(7 % 2.0)
print(7.5 % 2)
print(-7.5 % 2)
print(-7.5 % -2)
const infinity = 1e308 * 10
const not_a_number = infinity - infinity
print((infinity % 2).nan?())
print((not_a_number % 2).nan?())
print((5.0 % not_a_number).nan?())
