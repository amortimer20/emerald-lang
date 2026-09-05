## A static method is a value too, with the class in place of a receiver.
class Make {
    static func tag(text: String): String { return "<#{text}>" }
}

func apply(f: func(String): String, to: String) { print(f(to)) }

var wrap: func(String): String = Make.tag
print(wrap("a"))
apply(Make.tag, "b")
