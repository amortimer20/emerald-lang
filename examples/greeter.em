# Asks for a name and a few favorite words, then reports on them.
#
#     emerald run examples/greeter.em

var name = input("What is your name? ").trim()
if name.empty?() {
    name = "friend"
}
print("Hello, #{name.capitalize()}!")

var words = input("Name a few favorite words, separated by commas: ").split(",")
var longest = ""
for word in words {
    var cleaned = word.trim()
    longest = cleaned if cleaned.count > longest.count
}

print("""
    You gave #{words.count} words.
    The longest is "#{longest}", which is #{longest.count} characters long.
    Shouted, it is #{longest.upper()}; backwards, #{longest.reverse()}.
    """)
