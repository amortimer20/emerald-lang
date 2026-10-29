# Section 8.6's `group_by`: a group grows to hold however many items share its
# key, here more than the room a new group starts with.

const words = "a b c d e f g h ab cd ef".split(" ")
const by_length = words.group_by { word => word.count }
print(by_length)
print([1, 1, 1, 1, 1, 1, 1, 1, 1, 1].group_by { n => n }[1].or([]).count)
