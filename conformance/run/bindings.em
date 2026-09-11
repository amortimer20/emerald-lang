# Section 4.3: `var` permits rebinding, `const` does not. Section 5.3 lowers a
# compound assignment through the same operation as its binary form.

var total = 10
total += 5
total -= 3
total *= 2
print(total)

# `/=` follows `/`, which always produces a Float, so the name must hold one.
var share = 10.0
share /= 4
print(share)

var whole = 7
whole //= 2
print(whole)

const limit = 100
print(limit)
