# A rejected duplicate's body is still checked without crashing (review A2).

enum E {
    a
    b

    const b: E {
        return E.a
    }
}
