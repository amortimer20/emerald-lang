# A module of word lists. Fixed in the source for now — Emerald has no file reading yet,
# and a game that needs a data file is a poor first program in a language that cannot
# open one.

func hangman(): List<String> {
    return [
        "emerald", "compiler", "keyboard", "mountain", "language",
        "triangle", "notebook", "sandwich", "elephant", "umbrella",
        "penguin", "diamond", "gravity", "harvest", "journey"
    ]
}

# Wordle needs every word to be the same length, and this is that length.
const LENGTH = 5

func wordle(): List<String> {
    return [
        "crane", "slate", "adieu", "audio", "roast",
        "pilot", "ghost", "flick", "banjo", "quilt",
        "melon", "vivid", "proxy", "wharf", "zebra",
        "amber", "cider", "eagle", "fjord", "glyph"
    ]
}
