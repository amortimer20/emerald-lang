# Section 11.3: `Csv` does not encode or decode a generic type.
struct Pair[First, Second] {
    const first: First
    const second: Second
}

const rows = [Pair(first: 1, second: "one")]
print(Csv.encode(rows))
const decoded = Csv.decode("first,second\n1,one", as: List[Pair[Int, String]])
