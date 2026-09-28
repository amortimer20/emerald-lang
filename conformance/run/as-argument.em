# An argument named `as:` is an ordinary value in every call except
# `Json.decode`, where it names a type (15.9).
func describe(amount: Int, as: String): String {
    return "#{amount} as #{as}"
}

const unit = "meters"
print(describe(3, as: unit))
print(describe(3, as: "feet"))
