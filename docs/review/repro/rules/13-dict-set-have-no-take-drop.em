# Section 8.6: `take` and `drop` keep the receiver's kind for dictionaries and sets,
# using insertion order.
const ages: Dict[String, Int] = ["Cy": 14, "Ava": 12, "Bo": 13]
print(ages.take(2), ages.take(2).type_name)
print(ages.drop(2), ages.drop(5))
const colors: Set[String] = ["red", "green", "blue"]
print(colors.take(2), colors.take(2).type_name)
print(colors.drop(1), colors.take(0))
