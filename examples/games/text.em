# No class line, so this file is a module: every member is reached as Text.<name>
#
# Everything here exists because the standard library has no width. A string can be
# split, joined, and upper-cased, but it cannot be made eight characters wide — so a
# board, a table, or a menu has nowhere to start. These are the four functions the
# three games kept asking for.

func repeat(text: String, times: Int): String {
    var out = ""
    for i in 1..times {
        out += text
    }
    return out
}

# Widths are counted in characters, the same ones `for letter in word` walks — so an
# accented letter takes one column, which is what a person aligning a column means.
func pad_right(text: String, width: Int): String {
    return text + Text.repeat(" ", width - text.count())
}

func pad_left(text: String, width: Int): String {
    return Text.repeat(" ", width - text.count()) + text
}

func center(text: String, width: Int): String {
    var spare = width - text.count()
    return text if spare <= 0
    var left = spare // 2
    return Text.repeat(" ", left) + text + Text.repeat(" ", spare - left)
}

# A heading with a line under it, because every one of the games opens with one.
func banner(title: String) {
    print()
    print(title)
    print(Text.repeat("=", title.count()))
}
