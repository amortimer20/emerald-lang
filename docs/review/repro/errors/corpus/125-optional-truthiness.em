# Mistake: using an optional as a condition (line 3). Source: carry-over from Python; carry-over from JavaScript.
var found = [1, 2, 3].find { n => n > 1 }
if found {
    print("found it")
}
