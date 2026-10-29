# Section 15.9: a private field is never read from JSON, so it must have a default.
struct Account {
    const name: String
    const _token: String
}

const account = Json.decode("{\"name\": \"Ava\"}", as: Account)
