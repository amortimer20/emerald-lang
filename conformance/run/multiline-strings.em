# Section 5.1: a triple-quoted string starts on the line after its opening
# quotes, and the closing quotes' indentation is removed from every line.
# There is no final newline.

func banner(title: String): String {
    return """
        *** #{title} ***
          (indented two more)

        after a blank line
        """
}

print(banner("Emerald"))
print(banner("x").lines().count)
