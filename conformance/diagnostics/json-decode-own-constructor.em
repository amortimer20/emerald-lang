struct Score {
    const value: Int

    constructor(value: Int) {
        self.value = value
    }
}

struct Player {
    const score: Score
}

print(Json.decode("{}", as: Score))
print(Json.decode("null", as: Score?))
print(Json.decode("[]", as: List[Score]))
print(Json.decode("{}", as: Player))
