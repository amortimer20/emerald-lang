# An enum is a closed set of names and carries nothing else. Payloads are still out.
enum Bad {
    A, B

    var count: Int = 0

    abstract func speak(): String
}
