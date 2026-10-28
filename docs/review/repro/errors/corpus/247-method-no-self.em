# Mistake: using a field without self (line 7). Source: carry-over from Java/C (implicit this).
struct Rect {
    var width: Int
    var height: Int

    func area(): Int {
        return width * height
    }
}
print(Rect(2, 3).area())
