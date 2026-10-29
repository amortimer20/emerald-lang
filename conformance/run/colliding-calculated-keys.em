# Section 8.4: when calculated dictionary-literal keys collide at runtime, the later
# value wins without changing its insertion position.
func key(name: String): String {
    return name
}

const scores = [key("Ava"): 1, "Bo": 2, key("Ava"): 3]
print(scores)
