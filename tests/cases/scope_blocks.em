var total = 0
for i in 1..3 {
    var doubled = i * 2
    total += doubled
}
print(total)

var blocks = []
for i in 1..3 {
    blocks.add({ ignored => i })
}
print("#{blocks[0](0)} #{blocks[1](0)} #{blocks[2](0)}")
