# Section 15.9, decision 4: a field the document gives is read from it, and a
# missing one takes its default, or `nothing` when it is optional.
struct Settings {
    const name: String
    const volume: Int = 5
    const theme: String? = "dark"
    const note: String?
}

const given = Json.decode("{\"name\": \"Ada\", \"volume\": 9, \"theme\": null, \"note\": \"hi\"}", as: Settings)
print(given.volume, given.theme, given.note)
const missing = Json.decode("{\"name\": \"Ada\"}", as: Settings)
print(missing.volume, missing.theme, missing.note)

# A private field is never written, and never read: it keeps its default,
# whatever the document says.
struct Account {
    const owner: String
    const _balance: Int = 100
}
print(Json.encode(Account("Ada")))
print(Json.decode("{\"owner\": \"Ada\", \"_balance\": 1000000}", as: Account))

# A struct that holds itself, such as a tree, round-trips.
struct Node {
    const name: String
    const children: List[Node]
}
const tree = Node("root", [Node("left", []), Node("right", [Node("leaf", [])])])
const text = Json.encode(tree)
print(text)
print(Json.decode(text, as: Node) == tree)

# The two arguments can be named in either order.
print(Json.decode(as: List[Int], text: "[1, 2]"))

# A value of the wrong kind is described, as `Json`'s own conversions describe it.
try {
    Json.decode("{\"name\": \"Ada\", \"volume\": \"loud\"}", as: Settings)
} catch error: JsonError {
    print(error.message)
}
