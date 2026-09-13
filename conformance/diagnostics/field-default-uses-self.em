struct Box {
    var width: Int = 1
    var label: String = "#{self}"
    var area: Int = self.measure()

    func measure(): Int {
        return self.width
    }
}
