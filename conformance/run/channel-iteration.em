const pairs: Channel[(Int, String)] = Channel(capacity: 3)
pairs.send((1, "one"))
pairs.send((2, "two"))
pairs.send((3, "three"))
pairs.close()
for (number, word) in pairs {
    if number == 1 {
        continue
    }
    print(word)
    break
}
print(pairs.receive())
print(pairs.receive() == nothing)
