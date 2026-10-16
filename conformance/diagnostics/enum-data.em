# Section 12: building and using enum choices that carry data.
enum Action {
    move(x: Int, y: Int)
    say(text: String)
    wait
}

enum Shape {
    circle(radius: Float, radius: Float)
}

const a = Action.say()
const b = Action.move("left", 3)
const c = Action.move(x: 1, z: 2)
const d = Action.wait()
const e = Action.move
const f = Action()

enum Guests {
    named(names: List[String])
    nobody
}

var seats: Dict[Guests, Int] = []

struct Turn {
    const action: Action
}

const saved = Json.encode(Turn(Action.wait))
const shown = Console.table([Turn(Action.wait)])
const read = Json.decode("[]", as: List[Action])
