# Section 8.6's reduction starts from its required initial value and visits in order.

var calls = 0
const numbers = [1, 2, 3]
const total = numbers.reduce(10) { accumulator, number =>
    calls += 1
    return accumulator + number
}

const words = ["Emerald", "is", "expressive"]
const sentence = words.reduce("") { text, word =>
    if text.empty?() {
        return word
    } else {
        return "#{text} #{word}"
    }
}

const empty: List[Int] = []
print(total, calls, sentence, empty.reduce(99) { accumulator, number => accumulator + number })

# Changing a captured binding makes its own copy; reduce still sees its input.
var changing = [1, 2]
const stable_total = changing.reduce(0) { accumulator, number =>
    changing.append(99)
    return accumulator + number
}
print(stable_total, changing)
