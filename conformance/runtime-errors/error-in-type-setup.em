# A runtime error while a type's fields are set up shows what reached the type.
struct Config {
    var Config.ratio = Config.divide(1, 0)

    func Config.divide(a: Int, b: Int): Int {
        return a // b
    }
}

func show() {
    print(Config.ratio)
}

print("before")
show()
