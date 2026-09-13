var start: Int

struct Maker {
    var step: Int

    func make(): Int {
        return start + self.step
    }
}

const maker = Maker(1)
print(maker.make())
start = 1
