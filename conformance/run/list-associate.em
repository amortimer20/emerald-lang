# Section 8.6's `unique_by`, and its sequence-to-dictionary siblings
# `to_dictionary`, `associate`, and `associate_by`.

const words = ["pear", "fig", "kiwi", "plum", "lime"]
print(words.unique_by { word => word.count })

const pairs: List[(String, Int)] = [("a", 1), ("b", 2), ("a", 3)]
print(pairs.to_dictionary())

print(words.associate { word => (word, word.count) })
print(words.associate_by { word => word.count })
