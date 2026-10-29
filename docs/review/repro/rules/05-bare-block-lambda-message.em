# Section 3.4: a bare anonymous block is not a standalone scoping statement.
var total = 1
{
    var inner = 2
    print(inner)
}
print(total)
