# A Date that cannot exist raises DateTimeError at the program's own call, not
# inside the prelude code that checked it.
func deadline(): Date {
    return Date(2026, 2, 30)
}

print(deadline())
