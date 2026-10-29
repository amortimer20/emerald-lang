# A rejected duplicate's body is still checked without crashing (review A2).

func f() {
}

struct f {
    const v: Int

    func g(): Bool {
        return self.v > 1
    }
}
