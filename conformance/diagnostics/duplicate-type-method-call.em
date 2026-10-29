# A rejected duplicate's body is still checked without crashing (review A2).

struct S {
    func d(): Int {
        return 1
    }
}

struct S {
    func e(): Int {
        return self.d()
    }
}
