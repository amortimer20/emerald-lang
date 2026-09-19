# Section 5.4: an index outside the list is an error that names the index and
# the valid range.

func third(items: List[Int]): Int {
    return items[2]
}

print(third([1, 2]))
