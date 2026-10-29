# Mistake: comparing floats with == (line 3). Source: classic floating-point surprise.
var sum = 0.1 + 0.2
if sum == 0.3 {
    print("equal")
}
else {
    print("not equal")
}
