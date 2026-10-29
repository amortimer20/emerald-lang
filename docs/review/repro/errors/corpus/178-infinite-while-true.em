# Mistake: while true with no break (line 3). Source: review brief list (infinite loop).
var tries = 0
while true {
    tries += 1
}
print(tries)
