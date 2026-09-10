## print takes anything, so a forgotten () has no type to fail against — it would show
## <function> and say nothing. The two places that cannot catch it by type say so by name.
class Dog {
    func speak(): String { return "Woof" }
}

print(Dog().speak)
