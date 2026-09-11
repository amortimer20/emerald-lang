# A local does not leak out of the block that declared it, so the name is gone
# by the time it is read.

if true {
    var inner = 1
    print(inner)
}

print(inner)
