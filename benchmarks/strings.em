# String building: interpolation, character work, and joining.

var pieces: List[String] = []
for index in 0..<60000 {
    pieces.append("item-#{index}".upper())
}
const joined = pieces.join(",")
var vowels = 0
for character in joined.chars() {
    if "AEIOU".contains?(character) {
        vowels += 1
    }
}
print(joined.count, vowels)
