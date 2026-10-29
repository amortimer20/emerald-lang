# List.partition builds two lists and a tuple with no cleanup between them,
# so a failure after the first list leaks what was already built.
print([1, 2, 3, 4].partition { n => n % 2 == 0 })
