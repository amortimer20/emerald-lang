# Section 15.2: `input_maybe` reports the end of the input as absence, which is
# what makes reading until there is nothing left writable.
var line = input_maybe()
var count = 0
while line != nothing {
    count += 1
    print("#{count}: #{line.upper()}")
    line = input_maybe()
}
print("read #{count} lines")
