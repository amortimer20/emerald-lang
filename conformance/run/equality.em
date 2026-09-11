# Section 5.2: every type has `==` and `!=`. Only numbers have an order, which
# the checker enforces; see diagnostics/ordering-non-numbers.

print(true == true, true != false, false == true)
print(nothing == nothing, nothing != nothing)

var finished = 3 > 5
print(finished == false)

# Int and Float compare with each other by value.
print(2 == 2.0, 2 != 2.5)
