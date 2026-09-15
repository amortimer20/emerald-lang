var ages = ["Ava": 12, "Noah": 13]
print(ages, ages.count, ages.empty?())

## Section 8.3: a lookup can miss, so it answers with an optional.
print(ages["Ava"], ages["Zed"], ages["Zed"].or(0))

## Assignment inserts or replaces. A replaced value keeps its position.
ages["Mia"] = 9
ages["Ava"] = 20
print(ages)

print(ages.keys(), ages.values())
print(ages.entries())
print(ages.contains_key?("Ava"), ages.contains_key?("Zed"))
print(ages.contains_value?(13), ages.contains_value?(99))
print(ages.remove("Noah"), ages.remove("Zed"))
print(ages)

ages.merge(["Zed": 40, "Ava": 1])
print(ages)

for (name, age) in ages {
    print(name, age)
}
print(ages.map { (name, age) => "#{name}=#{age}" })
ages.each_with_index { (name, age), index =>
    print(index, name, age)
}
print(ages.any? { (name, age) => name == "Mia" }, ages.count_where { (_, age) => age >= 20 })
print(ages.find { (name, age) => age >= 1 })
print(ages.find_index { (name, age) => age >= 1 })
print(ages.reverse_each { (name, age) => print(name, age) })
func label_if_young(name: String, age: Int): String? {
    if age < 20 {
        return "#{name}=#{age}"
    }
    return nothing
}
print(ages.filter_map { (name, age) => label_if_young(name, age) })
const seen: {Int} = [1, 2, 3]
print(seen.find { value => value > 2 })

## Section 8.4: contents decide equality, not insertion order.
print(["a": 1, "b": 2] == ["b": 2, "a": 1])
print(["a": 1] == ["a": 2])

const empty: [String: Int] = []
print(empty, empty.empty?())
