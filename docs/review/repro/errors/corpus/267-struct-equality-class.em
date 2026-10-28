# Mistake: expecting two equal-looking objects to be == (line 5). Source: carry-over from Java/C (== vs equals).
class Card {
    var rank: Int
}
if Card(5) == Card(5) {
    print("same")
}
else {
    print("different")
}
