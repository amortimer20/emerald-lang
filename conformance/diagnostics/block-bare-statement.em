# Section 3.4: a bare anonymous block is not a standalone scoping statement.
const total = 1
{
    const inner = 2
    print(inner)
}
print(total)
