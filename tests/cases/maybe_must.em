## .must() says the value is there. It is the one construct that can turn a checked
## program back into a crash, so §3.6's naming rule applies to it hardest: the dangerous
## thing should not have the mildest name.
var here: Int? = "42".to_int_maybe()

print(here.must())
print(here.or(0))

var missing: Int? = nothing
print(missing.or(-1))

## Narrowing remains the primitive; .or and .must are the conveniences over it.
if here != nothing { print(here + 1) }

print(missing.must())
