# Section 6.4: equal inclusive endpoints visit once in every form; an equal half-open
# range is empty.
for number in 3..3 {
    print("range", number)
}
for number in 3.up_to(3) {
    print("up_to", number)
}
for number in 3.down_to(3) {
    print("down_to", number)
}
for number in (3..3).reverse() {
    print("reverse", number)
}
for number in (3..3).step(2) {
    print("step", number)
}
3.up_to(3) { number => print("up_to block", number) }
3.down_to(3) { number => print("down_to block", number) }
print((3..3).count, (3..<3).count, (3..<3).empty?())
for number in 3..<3 {
    print("never", number)
}
