enum Action {
    ## Moves to a square.
    move(x: Int, y: Int)
    wait
}

const step = Action.move(2, /*cursor*/
