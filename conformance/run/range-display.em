# A Range prints the way it would be written, so what is printed can be typed
# back in: a stepped range keeps its parentheses, and a range counting down is
# written with `down_to`.
print(1..5)
print(0..<24)
print((1..10).step(3))
print(5.down_to(1))
print(10.down_to(0).step(5))
print(-3..3)
