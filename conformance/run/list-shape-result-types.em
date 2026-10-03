var numbers = [1, 2, 3, 4, 5]
const chunks: List[List[Int]] = numbers.chunks(2)
const windows: List[List[Int]] = numbers.windows(3)
const pairs: List[(Int, Int)] = numbers.pairs()
print(chunks, chunks[0].count, chunks[2][0])
print(windows, windows[1].count, windows[2][2])
print(pairs, pairs[0].0, pairs[3].1)
const words = ["a", "b", "c"]
const word_chunks: List[List[String]] = words.chunks(2)
const word_windows: List[List[String]] = words.windows(2)
const word_pairs: List[(String, String)] = words.pairs()
print(word_chunks[0][1], word_windows[1][0], word_pairs[1].1)
const empty: List[Int] = []
const empty_chunks: List[List[Int]] = empty.chunks(2)
const empty_windows: List[List[Int]] = empty.windows(2)
const empty_pairs: List[(Int, Int)] = empty.pairs()
print(empty_chunks, empty_windows, empty_pairs)
