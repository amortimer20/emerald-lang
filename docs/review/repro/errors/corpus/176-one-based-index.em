# Mistake: starting a list loop at 1 (line 4). Source: review brief list (off-by-one).
var names = ["Ava", "Bo", "Cy"]
for i in 1..names.count {
    print(names[i])
}
