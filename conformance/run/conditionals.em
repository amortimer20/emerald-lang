# Section 6.2. Section 3.4 puts `else` on its own line, so a newline always
# separates it from the brace above.

var score = 14

if score >= 20 {
    print(1)
}
else if score > 10 {
    print(2)
}
else {
    print(3)
}

# Section 6.1 gives every block its own scope, and sibling scopes may reuse a name.
if true {
    var local = 1
    print(local)
}

if true {
    var local = 2
    print(local)
}
