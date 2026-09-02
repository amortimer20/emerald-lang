## A block is a function, so break cannot leave it — even though the loop is visible
## two lines up.
for x in [1, 2, 3] {
    [4, 5].each { y => break }
}
