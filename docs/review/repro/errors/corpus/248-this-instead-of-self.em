# Mistake: this instead of self (line 7). Source: carry-over from Java/C; carry-over from JavaScript.
struct Rect {
    var width: Int
    var height: Int

    func area(): Int {
        return this.width * this.height
    }
}
print(Rect(2, 3).area())
