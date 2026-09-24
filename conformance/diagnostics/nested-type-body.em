# A nested type's bodies are checked exactly as a top-level type's are.
class Outer {
    struct Inner {
        func broken(): Int {
            return "not an int"
        }
    }
}
