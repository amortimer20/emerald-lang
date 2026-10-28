# Mistake: has_key / containsKey (line 3). Source: carry-over from Python 2; carry-over from Java/C.
var ages = ["Ava": 12]
if ages.containsKey("Ava") {
    print("known")
}
