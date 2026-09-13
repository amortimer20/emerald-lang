func greet(name: String, punctuation: String = "!") {
    print(name + punctuation)
}

greet()
greet("Ava", "!", "?")
greet("Ava", mood: "glad")
greet("Ava", name: "Bo")
greet(name: "Ava", "!")
greet(punctuation: "?")
greet("Ava", punctuation: 3)
