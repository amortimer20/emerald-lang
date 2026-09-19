# Section 10.1: a class value is one shared object. Assigning or passing it
# shares the object, `const` fixes only which object a name refers to, and
# classes compare by identity.

class Window {
    var title: String
    var width: Int = 800
    var tags: List[String] = []
    var Window.opened = 0

    constructor(title: String) {
        self.title = title
        Window.opened += 1
    }

    func rename(to: String) {
        self.title = to
    }

    func tag(label: String) {
        self.tags.append(label)
    }

    var half: Int {
        get {
            return self.width // 2
        }
        set {
            self.width = value * 2
        }
    }

    func on_resize(): func(Int) {
        return { w => self.width = w }
    }
}

const main = Window("Main")
const alias = main
alias.rename("Renamed")
print(main.title)
main.tag("a")
alias.tags.append("b")
print(main.tags)
main.half = 300
print(alias.width)
main.width += 1
print(alias.width)

func grow(window: Window) {
    window.width = 1024
}
grow(main)
print(main.width)

const resize = main.on_resize()
resize(640)
print(alias.width)

const other = Window("Main")
print(main == alias, main == other)
print(Window.opened)

for w in [main, other] {
    w.title = "all"
}
print(main.title, other.title)

const windows = [main]
windows[0].rename("via list")
print(main.title)

func make(): Window {
    return Window("temp")
}
make().tags.append("lost but fine")
const renamer = main.rename
renamer("captured")
print(main.title)
print(main)
