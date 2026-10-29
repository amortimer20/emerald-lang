# Section 16.2: an assertion's message is reported as written, here an
# interpolated one, which is built when the assertion fails (review A3).

const n = 3
assert n == 4, "expected #{n} to be four"
