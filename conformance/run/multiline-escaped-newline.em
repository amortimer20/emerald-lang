# Section 5.1: a triple-quoted string's indentation is removed before escapes are
# processed, so an escaped `\n` is never taken for a line break.
const text = """
    first\n    second
    third
    """
print(text)
print(text.lines().count)
