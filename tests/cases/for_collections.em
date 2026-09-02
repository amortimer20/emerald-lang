## for walks a range, an array, or a string. Nothing else — there is no Iterable
## trait yet, deliberately.
for i in 1..3 { print(i) }

for word in ["apple", "fig"] {
    print("#{word} has #{word.length} letters")
}

## A string yields graphemes, so an accented letter is one turn of the loop.
for c in "héllo" { print(c) }

## The loop variable's type comes from what is walked, so methods on it are checked.
for n in [10, 20] { print(n + 1) }
