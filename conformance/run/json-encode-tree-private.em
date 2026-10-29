# Section 15.9: `Json.encode` accepts a struct that holds itself, such as a tree, and
# never writes a private field.
struct Node {
    const name: String
    const children: List[Node] = []
    const _visits: Int = 0
}

const tree = Node(name: "root", children: [Node(name: "leaf"), Node(name: "twig", children: [Node(name: "bud")])])
print(Json.encode(tree))
