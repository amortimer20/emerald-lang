# Section 14.1: `exit()` ends its path the way `raise` does, so a function
# whose other paths return needs no `return` after it, and a name it guards is
# known to be present afterwards.
func first_word(text: String): String {
    const words = text.split(" ")
    if words.count > 0 {
        return words[0]
    }
    exit(1)
}

func shout(name: String?): String {
    if name == nothing {
        exit(1)
    }
    return name.upper()
}

print(first_word("hello world"))
print(shout("ava"))
