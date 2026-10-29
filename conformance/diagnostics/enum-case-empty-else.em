# Section 12: a nonexhaustive enum statement `case` warns unless an explicit empty
# `else` acknowledges the remainder; only the first `case` here warns.
enum Light {
    red
    green
    amber
}

const light = Light.red
case light {
    when Light.red {
        print("stop")
    }
}
case light {
    when Light.red {
        print("stop")
    }
    else {
    }
}
