## A valueless return takes a guard. `unless` is never an expression, so it is always
## the guard; `if` is decided by whether a `then` follows before the line ends.
func announce(name: String, quiet?: Bool) {
    return if quiet?
    print("hello #{name}")
}

func score(win?: Bool): Int {
    return if win? then 10 else 0
}

func shout(text: String, ok?: Bool) {
    return unless ok?
    print(text.upper())
}

announce("ana", false)
announce("bob", true)
print(score(true))
print(score(false))
shout("yes", true)
shout("no", false)
