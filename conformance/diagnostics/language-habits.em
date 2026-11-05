var names = ["Ava", "Bo"]
names.remove(0)
var nums = [1, 2, 3]
nums.each { n =>
    break if n > 1
    print(n)
}
class BadScore {
    var message: String
}
raise BadScore("too high")
