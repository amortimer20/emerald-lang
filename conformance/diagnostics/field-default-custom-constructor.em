struct Box {
    var width: Int
    var area: Int = self.width * 2

    constructor(width: Int) {
        self.width = width
    }
}
