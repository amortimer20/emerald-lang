# Spellings other languages use inside a type, each answered with Emerald's,
# and each mistake reported once: the struct carries on at its next member, so
# its closing brace is not reported as closing nothing (17.2).
struct Counter {
    static var made = 0
    count: Int

    init(count: Int) {
        self.count = count
    }

    static func make(): Counter {
        return Counter(0)
    }

    func constructor(count: Int) {
    }

    func grow(self, by: Int) {
    }

    const doubled {
        return 0
    }

    var label: String
}

func greet(name: String) {
}

greet(name = "Ava")
