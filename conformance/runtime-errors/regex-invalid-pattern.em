# A pattern built as the program runs, and so not checked before it, raises
# RegexError at the program's own call when it cannot be compiled, not inside
# the prelude code that checked it.
func dates(digits: Int): Regex {
    return Regex('(\d{' + digits.to_string() + '}-\d{2}')
}

print(dates(4))
