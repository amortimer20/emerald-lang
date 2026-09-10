# §3.2 promised this and did not have it: a block that never returns a value has none to
# give, and map made a list of nothings that nothing complained about.

var numbers = [1, 2, 3]

var doubled = numbers.map { n =>
    print("looking at #{n}")
}

print(doubled.join(","))
