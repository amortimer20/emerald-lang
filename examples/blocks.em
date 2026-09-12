# Blocks: a function written inline, passed to something else, or kept in a
# variable and called later.
#
#     emerald run examples/blocks.em

const prices = [4, 12, 7, 30, 19]

# `each` runs the block once for every element.
prices.each { price => write("#{price} ") }
print("")

# `map` collects what the block produces into a new list.
const halves = prices.map { price => price / 2 }
print(halves)

# A block can be kept in a variable. On its own it says what it receives.
const label = { amount: Int => "$#{amount}" }
print(prices.map { price => label(price) })

# A block sees the variables around it, and changes to them are shared both
# ways: this is one `total`, not a copy.
var total = 0
prices.each { price => total += price }
print("Total: #{label(total)}")

# So a block can keep private state that outlives the function that made it.
func counter_from(start: Int): func(): Int {
    var next = start
    return { =>
        next += 1
        return next - 1
    }
}

const ticket = counter_from(1)
print("#{ticket()}, #{ticket()}, #{ticket()}")

# The counters are independent, because each call made its own `next`.
const other = counter_from(100)
print("#{other()} and #{ticket()}")

# `_` takes a value the block does not need.
var lines = 0
prices.each { _ => lines += 1 }
print("#{lines} prices")

# A named function is a value too, so it can be passed like any block.
func describe(price: Int): String {
    return "cheap" if price < 10
    return "fine" if price < 25
    return "steep"
}
print(prices.map(describe))
