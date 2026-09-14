# Section 6.3: `case` compares its subject with each alternative by `==`,
# runs the first arm that matches, and never falls through.

func describe(score: Int) {
    case score {
        when 1 {
            print("gold")
        }
        when 2, 3 {
            print("podium")
        }
        else {
            print("finished")
        }
    }
}

describe(1)
describe(3)
describe(9)

# A statement `case` may omit `else`; then no match does nothing.
case "tea" {
    when "coffee" {
        print("never printed")
    }
}

# A `case` that produces a value writes `then`, and needs an answer for
# everything: `else`, or every value of an enum or a `Bool`.
func medal(place: Int): String {
    return case place {
        when 1 then "gold"
        when 2 then "silver"
        when 3 then "bronze"
        else then "none"
    }
}

print(medal(2), medal(7))
const loud = true
print(case loud {
    when true then "LOUD"
    when false then "quiet"
})

# Without a subject, each `when` is a condition, and an arm knows the
# conditions above it failed.
const reading: Int? = 21
const summary = case {
    when reading == nothing then "no reading"
    when reading < 10 then "cold"
    when reading < 25 then "mild at #{reading}"
    else then "hot"
}
print(summary)

# The subject is evaluated once, and alternatives in order only until one
# matches.
func traced(value: Int, label: String): Int {
    print("evaluating #{label}")
    return value
}

case traced(2, "subject") {
    when traced(1, "first") {
        print("first")
    }
    when traced(2, "second"), traced(3, "third") {
        print("second")
    }
    when traced(2, "fourth") {
        print("fourth")
    }
}

# Arms that give `Int` and `Float` give a `Float`, and `nothing` in an arm
# makes the value optional.
const scale = case 1 {
    when 1 then 1
    else then 2.5
}
print(scale)
const nickname = case "Alexander" {
    when "Alexander" then "Alex"
    else then nothing
}
print(nickname.or("none"))

# Each arm is a scope of its own.
case 5 {
    when 5 {
        const note = "five"
        print(note)
    }
    else {
        const note = "other"
        print(note)
    }
}

# A statement `case` that covers every value of an enum runs one of its arms,
# so a name each arm assigns is assigned after it, and a function whose arms
# all return needs nothing after it.
enum Light {
    red
    amber
    green
}

func wait_seconds(light: Light): Int {
    case light {
        when Light.red {
            return 30
        }
        when Light.amber {
            return 3
        }
        when Light.green {
            return 0
        }
    }
}

var action: String
case Light.amber {
    when Light.red, Light.amber {
        action = "stop"
    }
    when Light.green {
        action = "go"
    }
}
print(action, wait_seconds(Light.red))

# A subject that may be absent matches `nothing` as an alternative.
var colour: Light? = nothing
for step in 1..2 {
    print(case colour {
        when nothing then "unlit"
        when Light.red then "red"
        when Light.amber, Light.green then "lit"
    })
    colour = Light.red
}
