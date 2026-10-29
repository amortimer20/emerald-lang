# Section 16.2: `assert condition, message` reports the message. With an interpolated
# string literal as the message, the report prints garbage bytes instead:
#   UUUUUUUUUU Left was 3; right was 4.
# where "expected 3 Left was 3; right was 4." is expected (a message held in a
# variable first prints correctly).
const n = 3
assert n == 4, "expected #{n}"
