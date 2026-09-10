for n in 1..10 {
    continue if n % 2 == 0
    break if n > 7
    print(n)
}

var i = 0
while true {
    i += 1
    continue if i < 5
    break
}
print(i)

## break leaves the inner loop only.
for a in 1..3 {
    for b in 1..3 {
        break if b == 2
        print("#{a},#{b}")
    }
}
