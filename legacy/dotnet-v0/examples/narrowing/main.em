var maybe = "42".to_int_maybe()

# Narrowed by the check: inside here, maybe is an Int
if maybe != nothing {
    print("got #{maybe.abs()}")
}
else {
    print("not a number")
}
