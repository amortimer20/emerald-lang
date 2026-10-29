# Section 8.3: an optional-valued dictionary reads a stored `nothing` and a miss alike,
# `contains_key?` tells them apart, and assigning `nothing` stores an entry rather than
# deleting one.
var nicknames: Dict[String, String?] = ["Ava": "Avie", "Bo": nothing]
print(nicknames["Bo"] == nothing, nicknames["Cy"] == nothing)
print(nicknames.contains_key?("Bo"), nicknames.contains_key?("Cy"))
nicknames["Ava"] = nothing
print(nicknames.count, nicknames.contains_key?("Ava"))
print(nicknames)
