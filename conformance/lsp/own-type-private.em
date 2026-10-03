class Example {
    const Example._hidden: Int = 2
    func Example._secret(): Int {
        return 0
    }
    func probe() {
        Example./*cursor*/
    }
}
