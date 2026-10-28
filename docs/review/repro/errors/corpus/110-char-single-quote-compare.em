# Mistake: comparing a character with single quotes (line 3). Source: carry-over from Java/C.
var word = "apple"
if word[0] == 'a' {
    print("starts with a")
}
