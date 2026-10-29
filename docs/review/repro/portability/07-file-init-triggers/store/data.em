const greeting = build("greeting")

func build(label: String): String {
    print("  setting up #{label}")
    return label
}

class Plain {
    var x: Int = 0

    func Plain.hello(): String {
        return "hello"
    }
}

enum Mood {
    happy
}
