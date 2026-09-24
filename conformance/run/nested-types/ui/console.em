# Nested types (14.3): naming and visibility relationships, reached by path.
class Console {
    var _secret: Int = 7

    enum Color {
        red, green

        func describe(): String {
            return case self {
                when Console.Color.red then "warm"
                when Console.Color.green then "cool"
            }
        }
    }

    struct Pair {
        var left: Int
        var right: Int

        func swapped(): Self {
            return Console.Pair(self.right, self.left)
        }

        func Pair.zero(): Console.Pair {
            return Console.Pair(0, 0)
        }

        struct Deep {
            var note: String
        }
    }

    # Code inside `Console`'s braces reaches its private members (10.5).
    struct Peeker {
        func peek(console: Console): Int {
            return console._secret
        }
    }

    func Console.favorite(): Console.Color {
        return Console.Color.green
    }
}
