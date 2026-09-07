## The same mistake in a condition. Expect is shared by if, while and assert, so all
## three now name the call rather than the type the value does not have.
var n = 5

if n.even? {
    print("even")
}
