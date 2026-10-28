# Text and dictionaries: counting the words of a generated text.

const vocabulary = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "and", "runs"]
const generator = Random(11)
var lines: List[String] = []
for _ in 0..<20000 {
    var line: List[String] = []
    for _ in 0..<12 {
        line.append(vocabulary[generator.next(0..<vocabulary.count)])
    }
    lines.append(line.join(" "))
}
const text = lines.join("\n")

var counts: Dict[String, Int] = []
for word in text.words() {
    counts[word] = counts[word].or(0) + 1
}
const top = counts.entries().sort_by { entry => -entry.1 }
print(top[0].0, top[0].1, counts.count)
