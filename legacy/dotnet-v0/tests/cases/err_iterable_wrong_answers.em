## The useful half of a bound trait is that a mismatch says which binding is wrong.
##
## A Set walks Ints perfectly well, so it is not refused over Item — it is refused over
## Filtered, because narrowing a Set gives a Set where this asked for a List. The second
## call is the ordinary case, wrong about Item instead.

func strict(items: Iterable<Item=Int, Filtered=List<Int>>): Int {
    return items.count()
}

print(strict([1, 2, 3].to_set()))
print(strict(["a", "b"]))
