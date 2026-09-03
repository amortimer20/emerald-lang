## The expression is rendered back from the tree, so what is reported is what was
## written — interpolation, indexing, blocks and all.
var scores = ["ada": 1]
assert scores["ada"].or(0) == 2
