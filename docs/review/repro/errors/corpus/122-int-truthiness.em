# Mistake: using an Int as a condition (line 3). Source: carry-over from Python; guide docs/language/core.md.
var lives = 3
if lives {
    print("still playing")
}
