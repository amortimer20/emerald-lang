# Section 4.5: optionals never nest, so an optional-producing operation on an optional
# type yields that same type; the companion operation tells the cases apart.
const ages: Dict[String, Int?] = ["Ava": nothing]
const stored = ages["Ava"]
const missing = ages["Bo"]
print(stored.type_name, missing.type_name)
print(stored == nothing, missing == nothing)
print(ages.contains_key?("Ava"), ages.contains_key?("Bo"))
const scores: List[Int?] = [nothing, 4]
const found = scores.find { score => score == nothing }
print(found == nothing)
print(scores.find_index { score => score == nothing })
const value: Int = found.or(7)
print(value)
