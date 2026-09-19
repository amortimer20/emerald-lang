# Section 7.4: a block captures the variables it can see, not copies of them.
var count = 0
const bump = { => count += 1 }
bump()
bump()
print(count)
count = 10
bump()
print(count)

# The variables outlive the call that made them, one set for each call.
func counter_from(start: Int): func(): Int {
    var next = start
    return { =>
        next += 1
        return next - 1
    }
}

const first = counter_from(1)
const second = counter_from(100)
print("#{first()} #{first()} #{second()} #{first()}")

# Section 6.1: a loop variable is fresh each iteration, so each block keeps its
# own value rather than the last one.
var blocks: List[func(): Int] = []
for i in 1..3 {
    blocks.append({ => i })
}
print(blocks.map { block => block() })

# A block sees a list by reference to the same variable, so the change shows.
var names = ["Ada"]
const add = { name: String => names.append(name) }
add("Grace")
add("Alan")
print(names)
