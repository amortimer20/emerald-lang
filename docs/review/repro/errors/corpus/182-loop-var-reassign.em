# Mistake: assigning to the loop variable (line 4). Source: carry-over from Java/C.
for i in 1..5 {
    if i == 2 {
        i = 4
    }
    print(i)
}
