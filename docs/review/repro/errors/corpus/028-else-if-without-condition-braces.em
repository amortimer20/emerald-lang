# Mistake: else if condition wrapped in parentheses only (line 9). Source: carry-over from Java/C.
var x = 5
if (x > 10) {
    print("big")
}
else if (x > 3) {
    print("medium")
}
else (x > 0) {
    print("small")
}
