# Mistake: removing from a list while looping over it (line 5). Source: Kohn 2019 (The Error Behind the Message, Python novices); guide docs/language/collections-and-ranges.md.
var numbers = [1, 2, 3, 4]
for n in numbers {
    if n % 2 == 0 {
        numbers.remove(n)
    }
}
print(numbers)
