# Section 12: an enum lists its values first and stores nothing else.

enum Light {
    red
    green

    const brightness: Int
    var level: Int = 3

    constructor() {
    }

    func glow(): Int {
        return 1
    }

    amber
}

enum Empty {
}

enum Shade extends Light {
    dark
}
