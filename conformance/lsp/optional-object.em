class Example {
    const value: Int
    func answer(): Int {
        return self.value
    }
}
func maybe_example(): Example? {
    return nothing
}
const example = maybe_example()
example?./*cursor*/
