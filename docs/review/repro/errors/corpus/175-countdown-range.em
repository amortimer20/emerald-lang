# Mistake: a range written high to low (line 2). Source: review brief list (off-by-one); guide docs/language/collections-and-ranges.md.
for i in 10..1 {
    print(i)
}
print("liftoff")
