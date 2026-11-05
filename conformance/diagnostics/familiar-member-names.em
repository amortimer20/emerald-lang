const names = ["Ava", "Bo"]
const ages = ["Ava": 12]
const word = "hello"
const tags: Set[Int] = [1]
print(names.size())
print(names.isEmpty)
print(ages.containsKey("Ava"))
print(word.toUpperCase())
print(", ".join(names))
print("Hello {}".format(word))
print(word.charAt(0))
print(word.pad_left(8))
print(tags.intersect([1]))
