enum Outcome[Value] {
    success(value: Value)
    failure(message: String)
}

const outcome = Outcome.success([])
