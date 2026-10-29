# Section 15.9: a class, a function, or byte data is a checking error for `Json.encode`.
class Player {
}

func shout(text: String): String {
    return text.upper()
}

print(Json.encode(Player()))
print(Json.encode(shout))
print(Json.encode(Bytes.from_list([1])))
