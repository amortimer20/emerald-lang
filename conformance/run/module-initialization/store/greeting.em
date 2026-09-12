const greeting = build()

func build(): String {
    print("  setting up the store")
    return "hello"
}

func shout(): String {
    return greeting.upper() + "!"
}
