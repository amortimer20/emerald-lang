# Mistake: factorial overflowing Int (line 4). Source: review brief list (integer surprises).
var product = 1
for n in 1..25 {
    product *= n
}
print(product)
