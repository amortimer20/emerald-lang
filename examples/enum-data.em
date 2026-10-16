# Enums whose choices carry data

## A finished download has a path; a failed one has a message. A download that is
## still waiting has neither, and none of them can be missing what it needs.
enum Download {
    waiting
    finished(path: String)
    failed(message: String)
}

## `case` picks the choice, then names its data for that arm alone.
func describe(download: Download): String {
    return case download {
        when Download.waiting then "Waiting to download"
        when Download.finished(path) then "Saved to #{path}"
        when Download.failed(message) then "Download failed: #{message}"
    }
}

const downloads = [
    Download.waiting,
    Download.finished("report.pdf"),
    Download.failed(message: "the disk is full"),
]
for download in downloads {
    print(describe(download))
}

## Different choices need different data: a circle has no width.
enum Shape {
    circle(radius: Float)
    rectangle(width: Float, height: Float)

    const area: Float {
        return case self {
            when Shape.circle(radius) then Math.pi * radius * radius
            when Shape.rectangle(width, height) then width * height
        }
    }
}

const shapes = [Shape.circle(1.0), Shape.rectangle(width: 4.0, height: 3.0)]
for shape in shapes {
    print("#{shape} has an area of #{shape.area.format(decimal_places: 2)}")
}

## One list holds choices with two, one, or no data items. `_` ignores one.
enum Action {
    move(x: Int, y: Int)
    say(text: String)
    wait
}

const script = [Action.move(2, 3), Action.say("Hello!"), Action.wait, Action.move(0, 1)]
var steps_north = 0
for action in script {
    case action {
        when Action.move(_, y) {
            steps_north += y
            print("Move #{y} north")
        }
        when Action.say(text) {
            print("Say \"#{text}\"")
        }
        when Action.wait {
            print("Wait a turn")
        }
    }
}
print("#{steps_north} steps north in all")

## Matched data cannot change; a `var` copy can, and the enum keeps its own.
enum Party {
    guests(names: List[String])
}

const party = Party.guests(["Ada", "Grace"])
case party {
    when Party.guests(names) {
        var invited = names
        invited.append("Alan")
        print("Invited: #{invited}")
    }
}
print(party)
