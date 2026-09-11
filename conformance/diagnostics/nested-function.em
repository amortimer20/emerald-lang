# Nested named functions are deferred. The whole declaration is still read, so
# this is the only diagnostic.

if true {
    func helper() {
        print(1)
    }
}
