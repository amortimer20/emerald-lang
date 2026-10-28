# Mistake: using a List as a condition (line 3). Source: carry-over from Python.
var items = [1, 2]
while items {
    items.remove_last()
}
