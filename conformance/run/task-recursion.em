func descend(n: Int): Int {
    if n == 0 {
        return 0
    }
    return 1 + descend(n - 1)
}

Tasks.run { tasks =>
    const deep = tasks.start { => descend(950) }
    print(deep.result())
}
