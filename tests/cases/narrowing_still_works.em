## The rule has to take away only what it must. A variable nothing else can reach is
## still narrowed by a check, including one a block declares for itself — blocking those
## would cost far more than it protects.
var maybe = "42".to_int_maybe()

if maybe != nothing {
    print(maybe.abs())
}

func run() {
    var text: String? = "inside a function"
    if text != nothing { print(text.length()) }
}

run()

[1, 2].each { i =>
    var local: String? = nothing
    local = "declared in the block"
    if local != nothing { print(local.length()) }
}

var found = ["a", "bb"].find { word => word.length() > 1 }
if found != nothing { print(found.upper()) }

## The fix the diagnostic suggests: copy first, then check the copy.
var name: String? = "ada"

func clear() {
    name = nothing
}

var it = name
if it != nothing {
    clear()
    print(it.length())
}
