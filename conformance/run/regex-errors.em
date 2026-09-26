# Section 15.4's RegexError quotes the pattern, gives the position of the
# problem in it counted in characters, and says what to do instead.
func attempt(pattern: String) {
    try {
        print(Regex(pattern))
    }
    catch error: RegexError {
        print(error.message)
    }
}

attempt('(\d+')
attempt('a)')
attempt('*a')
attempt('a**')
attempt('[z-a]')
attempt('[]')
attempt('x{2000}')
attempt('x{5,2}')
attempt('\q')
attempt('é\')

# Constructs other engines accept, refused because they could make matching
# take far longer than the text is long.
attempt('(a)\1')
attempt('a(?=b)')
attempt('(?<!a)b')
attempt('a++')
attempt('(?>a)')

# Other spellings, each with the one Emerald uses.
attempt('(?i)abc')
attempt('(?P<year>\d+)')
attempt('\Aabc')
attempt('\p{L}')

# A RegexError is a RuntimeError. (A pattern written as a literal is checked
# before the program runs, so this one is built as it runs.)
const unclosed = "("
try {
    Regex(unclosed)
}
catch error: RuntimeError {
    print("caught as RuntimeError")
}
