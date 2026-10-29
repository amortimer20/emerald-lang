# docs/library/dict.md: map_keys produces "a new Dict the same size as the
# receiver". Colliding produced keys shrink it; which value survives is unstated.
const scores: Dict[String, Int] = ["ava": 1, "Ava": 2, "AVA": 3]
const folded = scores.map_keys { name => name.lower() }
print(folded, folded.count, scores.count)
