## Section 3.3 lets a name end in `?` or `!`. Each marker has to survive beside
## the operator it resembles: `?.` for optional chaining and `!=` for inequality.

func empty?(names: List[String]): Bool {
    return names.count == 0
}

var names = ["Ava", "Noah"]
var ready = empty?(names)
names.sort!()

var before = 1
var after = 2
var changed = before != after
