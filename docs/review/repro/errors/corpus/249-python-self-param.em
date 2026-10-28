# Mistake: self as an explicit parameter (line 6). Source: carry-over from Python.
struct Rect {
    var width: Int
    var height: Int

    func area(self): Int {
        return self.width * self.height
    }
}
print(Rect(2, 3).area())
