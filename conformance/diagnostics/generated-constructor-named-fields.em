struct Box {
    var width: Int = 1
    var height: Int
}

print(Box(2))
print(Box(height: 2, depth: 3))
print(Box(height: 2, width: "wide"))
