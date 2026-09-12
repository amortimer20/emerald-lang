struct Index {
    var labels: [Wrapper: String]
}

struct Wrapper {
    const payload: Payload
}

struct Payload {
    var values: [Int]
}
