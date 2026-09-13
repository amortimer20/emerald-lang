struct Ticker {
    var count: Int

    const next: Int {
        self.count += 1
        return self.count
    }
}
