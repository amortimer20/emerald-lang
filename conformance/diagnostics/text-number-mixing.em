var age = input("How old are you? ")
print(age + 1)
if age >= 18 {
    print("adult")
}
if age == 18 {
    print("exactly")
}
var total = 0
for part in "1,2,3".split(",") {
    total += part
}
var decimal = 2.5
print(decimal * age)
var line = "x"
line += 5
var choice = input("1 or 2? ")
case choice {
    when 1 {
        print("one")
    }
    else {
        print("other")
    }
}
