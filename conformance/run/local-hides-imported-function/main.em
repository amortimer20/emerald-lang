using Text

# A local holding a block hides the imported function of the same name, for a
# call exactly as for a read.
func greet() {
    const shout = { text: String => text.upper() + "!" }
    print(shout("hi"))
}
greet()
print(shout(1, 2))
