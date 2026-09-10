## filter answers Filtered, and a List, a Set and a class that writes its own all disagree
## about what Filtered is. The annotation here never said, so the call is refused by name
## rather than guessed at — guessing is what would let this be checked as List<Int> and
## evaluated as Set<Int>, which is the failure the whole design exists to prevent.
##
## The fix the diagnostic names is real and tested next door: say Filtered=List<Int>, and
## narrowing works again on exactly the types that answer it that way.

func narrow(items: Iterable<Item=Int>): Int {
    return items.filter { n => n > 1 }.count()
}

print(narrow([1, 2, 3]))
