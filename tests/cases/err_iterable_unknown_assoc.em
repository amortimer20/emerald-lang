## Answering a name the trait never declared. Caught where it is written rather than
## silently binding nothing and leaving the requirement open, and the message lists what
## there actually is to answer — which on a trait is a short, closed list.

func typo(items: Iterable<Nope=Int>): Int {
    return items.count()
}

print(typo([1]))
