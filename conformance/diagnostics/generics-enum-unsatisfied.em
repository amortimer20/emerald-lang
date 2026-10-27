enum Tree[Item with Ordered] {
    empty
    branch(left: Tree[Item], item: Item, right: Tree[Item])
}

struct Player {
    const name: String
}

const tree = Tree.branch(Tree.empty, Player("Ava"), Tree.empty)
