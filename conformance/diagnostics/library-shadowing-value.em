# The same, for a value of the program's own `Date`: a method or field only the
# library's `Date` has is explained at that use, and `Emerald.Date` still works.
struct Date {
    const day: Int
}

const today = Date(27)
print(today.weekday)
print(today.year)
print(Emerald.Date(2026, 9, 28).weekday)
