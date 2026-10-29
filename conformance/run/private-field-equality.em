# Section 10.5: privacy limits which code can reach a member, not what a value is, so
# equality still includes private fields.
struct Token {
    var name: String
    var _secret: Int = 0

    func Token.with_secret(name: String, secret: Int): Token {
        return Token(name: name, _secret: secret)
    }
}

print(Token(name: "a") == Token(name: "a"))
print(Token.with_secret("a", 1) == Token.with_secret("a", 2))
print(Token.with_secret("a", 1) == Token.with_secret("a", 1))
