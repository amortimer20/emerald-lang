# Mistake: using a / result as a range bound (line 3). Source: review brief list (integer division surprise).
var n = 10
for i in 0..<n / 2 {
    print(i)
}
