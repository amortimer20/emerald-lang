# A type-level field's type is inferred where it is first needed, even inside
# a block, and stays known after the block ends.
struct Counter {
    var Counter.total = 1
}

if true {
    print(Counter.total)
}
Counter.total += "one"
