# A module's own members answer to their bare names. Every file could already see every
# other file's top-level functions that way, so a file's own contents were the single
# thing it had to qualify - the asymmetry ran the wrong way round.

const MARK = "!"
var used: Int = 0

func shout(word: String): String {
    used += 1
    return word.upper() + MARK
}

func twice(word: String): String {
    return shout(word) + " " + shout(word)
}

func used_so_far(): Int {
    return used
}
