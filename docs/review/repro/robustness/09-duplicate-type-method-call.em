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
