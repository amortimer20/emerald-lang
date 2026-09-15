const ages = ["Ava": 12, "Ben": 17, "Cora": 9]
print(ages.map_keys { name => name.upper() })
print(ages.map_values { age => age * 2 })
print(ages.filter { (name, age) => age >= 10 })
print(ages.reject { (name, age) => age >= 10 })
