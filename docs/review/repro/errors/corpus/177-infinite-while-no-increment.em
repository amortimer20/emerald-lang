# Mistake: while loop that never changes its counter (line 3). Source: review brief list (infinite loop); McCall & Kolling 2019 (meaningful categories of novice errors).
var i = 0
while i < 5 {
    print(i)
}
