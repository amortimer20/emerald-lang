# Finding 01: group_by panics (debug) once one group reaches five items.
# Expected (list.md, group_by): [1: [1, 1, 1, 1, 1]]
print([1, 1, 1, 1, 1].group_by { x => x })
