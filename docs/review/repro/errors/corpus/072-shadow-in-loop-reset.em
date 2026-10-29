# Mistake: redeclaring an accumulator inside the loop (line 4). Source: review brief list (shadowing).
var total = 0
for n in [1, 2, 3] {
    var total = total + n
}
print(total)
