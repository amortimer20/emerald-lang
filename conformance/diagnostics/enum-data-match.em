# Section 12: mistakes in naming a choice's data in `case`.
enum Action {
    move(x: Int, y: Int)
    say(text: String)
    wait
}

func double(value: Int): Int {
    return value * 2
}

const action = Action.wait
const text = "outer"
case action {
    when Action.move(y, x) {
        print(x)
    }
    when Action.say(words), Action.wait {
        print(1)
    }
}
case action {
    when Action.move(a, a) {
        print(a)
    }
    when Action.say(text) {
        print(text)
    }
    else {
    }
}
case action {
    when Action.move(0, y) {
        print(y)
    }
    when Action.say(text: t) {
        print(t)
    }
    else {
    }
}
case action {
    when Action.move(only) {
        print(only)
    }
    when Action.say(words) {
        words = "changed"
    }
    else {
    }
}
case 4 {
    when double(_) {
        print(4)
    }
    else {
    }
}
case action {
    when Action.move(across, down) {
        print(across + down)
    }
    else {
    }
}
print(across)

func first(move: Action): Int {
    case move {
        when Action.move(across_first, _) {
            return across_first
        }
        else {
        }
    }
    return 0
}

func second(): Int {
    return across_first
}
