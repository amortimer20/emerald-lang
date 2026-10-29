# Mistake: inclusive range to count, index out of range (line 4). Source: review brief list (off-by-one); guide docs/language/core.md.
var names = ["Ava", "Bo", "Cy"]
for i in 0..names.count {
    print(names[i])
}
