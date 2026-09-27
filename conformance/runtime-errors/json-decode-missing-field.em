struct Score {
    const name: String
    const points: Int
}

Json.decode("{\"name\": \"Ada\"}", as: Score)
