struct Share {
    var total: Int
    var parts: Int
    var each: Int = self.total // self.parts
}

print(Share(total: 10, parts: 0))
