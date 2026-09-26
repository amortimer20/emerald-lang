# A pattern that cannot be compiled raises RegexError at the program's own
# call, not inside the prelude code that checked it.
func dates(): Regex {
    return Regex('(\d{4}-\d{2}')
}

print(dates())
