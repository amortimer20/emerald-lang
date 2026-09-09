## A dictionary's element is a pair everywhere now, not a pair coming out of find and two
## separate values going into a block. `(key, value)` is the third place the destructure
## from `var (name, score) =` and `for (key, value) in` is wanted, and the parentheses are
## what tell one thing coming apart from two things arriving.

var scores = ["ada": 36, "bo": 7]

scores.each { (who, age) =>
    print("#{who} is #{age}")
}

## The same element, taken whole. This used to hand over the key while the checker called
## it a Pair — the one-parameter block is what made the disagreement visible.
scores.each { entry =>
    print("#{entry.type_name()} #{entry.first()} => #{entry.second()}")
}

## Narrowing still gives back a dictionary, and mapping still gives back a list, exactly
## as §3.7 settled before any of this.
print(scores.filter { (who, age) => age > 10 }.type_name())
print(scores.map { (who, age) => who }.type_name())
print(scores.count())

## each_with_index is genuinely two things arriving, so it keeps the bare form — and on a
## dictionary the first of them is the pair.
scores.each_with_index { entry, at =>
    print("#{at}: #{entry.first()}")
}

## Which makes a dictionary satisfy Iterable like everything else that walks.
func how_many(items: Iterable<Item=Pair<String, Int>>): Int {
    var seen = 0
    items.each { (who, age) => seen += 1 }
    return seen
}

print(how_many(scores))
