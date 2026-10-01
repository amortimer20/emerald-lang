struct Box {
    var items: List[Int]
    func prune() {
        self.items.remove_if { n => n % 2 == 0 }
    }
}
const box = Box([1, 2, 3, 4])
box.prune()
