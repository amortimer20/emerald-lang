# Section 12: what a `case` that names choice data must also cover.
enum Action {
    move(x: Int, y: Int)
    say(text: String)
    wait
}

enum Other {
    pick(n: Int)
}

const action = Action.wait
const sum = case action {
    when Action.move(a, b) then a + b
    when Action.wait then 0
}
case action {
    when Action.say(words) {
        print(words)
    }
    when Action.say(again) {
        print(again)
    }
    when Action.say {
        print(1)
    }
    else {
    }
}
case action {
    when Other.pick(n) {
        print(n)
    }
    else {
    }
}
case action {
    when Action.move(_, _) {
        print("moved")
    }
}

enum Guests {
    named(names: List[String])
}

case Guests.named(["Ada"]) {
    when Guests.named(names) {
        names.append("Grace")
    }
}
