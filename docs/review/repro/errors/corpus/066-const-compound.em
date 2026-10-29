# Mistake: += on a const counter (line 4). Source: review brief list.
const count = 0
for i in 1..3 {
    count += 1
}
print(count)
