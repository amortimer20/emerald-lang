# Regular expressions: the programs a beginner most often wants to write.
# Run it with `emerald run examples/regex.em`. Patterns are written in single
# quotes, which keep every backslash as it is.

# Is this a valid ticket code?
const ticket = Regex('[A-Z]{3}-\d{4}')
for code in ["ABC-1234", "abc-1234", "ABCD-12"] {
    if ticket.matches?(code) {
        print("#{code} is a ticket")
    }
    else {
        print("#{code} is not: tickets look like ABC-1234")
    }
}

# Pull every number out of a line and add them up.
const numbers = Regex('\d+').find_all("3 apples, 12 pears").map { found => found.text.to_int() }
print("#{numbers} add up to #{numbers.sum()}")

# Split on any run of commas and spaces.
print(Regex('[,\s]+').split("red, green,blue"))

# Read the parts of a date written the American way.
const us_date = Regex('(?<month>\d{1,2})/(?<day>\d{1,2})/(?<year>\d{4})')
const found = us_date.find("Due 9/25/2026")
if found != nothing {
    print(Date(found.named("year").to_int(), found.named("month").to_int(), found.named("day").to_int()))
}

# Tidy text: squeeze runs of spaces, and double every number.
print(Regex('\s+').replace_all("too    many   spaces", " "))
print(Regex('\d+').replace_each("3 apples") { found => (found.text.to_int() * 2).to_string() })

# Case does not have to match, and a character is a character: é is one,
# however it was typed.
const greeting = Regex('hello', ignore_case: true)
print(greeting.contains_match?("Say HELLO!"), Regex('^caf.$').matches?("cafe\u{301}"))

# Text from a user can become a pattern that matches it exactly.
const search = "$4.99 (sale)"
print(Regex(Regex.escape(search)).find_all("Was $5.99, now $4.99 (sale)!"))
