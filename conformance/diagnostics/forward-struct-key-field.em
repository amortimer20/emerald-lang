struct Index {
    var labels: Dict[Wrapper, String]
}

struct Wrapper {
    const payload: Payload
}

struct Payload {
    var values: List[Int]
}
