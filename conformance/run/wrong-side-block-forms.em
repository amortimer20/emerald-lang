# Section 6.4: the `up_to` and `down_to` wrong-side rule applies to their block forms:
# a target on the wrong side counts nothing.
const count = 0
count.down_to(1) { number => print("down", number) }
const high = 5
high.up_to(1) { number => print("up", number) }
print("done")
