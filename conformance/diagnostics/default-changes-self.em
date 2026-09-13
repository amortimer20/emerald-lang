# A default works out a value for the call, like a getter (10.3), so it may not
# change `self`.
struct Ids {
    var next: Int

    func take(): Int {
        self.next += 1
        return self.next
    }

    func show(id: Int = self.take()) {
        print(id)
    }
}
