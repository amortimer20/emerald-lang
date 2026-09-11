# A small grade book: the average, the highest score, how many scores beat the
# average, and the scores in order, sorted without changing the original list.

func average(scores: [Int]): Float {
    var total = 0
    for score in scores {
        total += score
    }
    return total / scores.count
}

func highest(scores: [Int]): Int {
    var best = scores[0]
    for score in scores {
        best = score if score > best
    }
    return best
}

# A parameter cannot change, so this sorts its own copy and returns it.
func sorted(scores: [Int]): [Int] {
    var result = scores
    for pass in 0..<result.count {
        for index in 0..<result.count - 1 - pass {
            if result[index] > result[index + 1] {
                var swap = result[index]
                result[index] = result[index + 1]
                result[index + 1] = swap
            }
        }
    }
    return result
}

var scores = [72, 95, 64, 88, 91]
var mean = average(scores)
var above = 0
for score in scores {
    above += 1 if score > mean
}

print(mean, highest(scores), above)
print(sorted(scores))
print(scores)
