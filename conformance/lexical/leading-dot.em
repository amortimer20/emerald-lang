# Section 3.1: a line that begins with a member dot continues the line before
# it, so a method chain can wrap. Blank lines and comments between are skipped.

var count = numbers
    .filter { number => number > 0 }

    # still the same statement
    .count

var city = user
    ?.address
    ?.city
