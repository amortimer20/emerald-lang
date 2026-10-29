# Json.decode into a struct whose struct allocation fails: Heap.createStruct
# frees `fields`, then jsonDecodePlainStruct frees them again (double free).
struct Point {
    const x: Int
    const y: Int
}
print(Json.decode("{\"x\": 1, \"y\": 2}", as: Point))
