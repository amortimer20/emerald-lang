# Section 6.4: only a literal `true` makes a `while` complete only through `break`;
# a constant that is true is still a loop that might not run.
const forever = true

func first(): Int {
    while true {
        return 1
    }
}

func second(): Int {
    while forever {
        return 2
    }
}

func third() {
    var answer: Int
    while forever {
        answer = 3
        break
    }
    print(answer)
}
