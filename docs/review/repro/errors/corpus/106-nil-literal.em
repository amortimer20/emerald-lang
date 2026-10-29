# Mistake: nil instead of nothing (line 3). Source: carry-over from Ruby.
var winner: String? = "Ava"
if winner == nil {
    print("no winner")
}
