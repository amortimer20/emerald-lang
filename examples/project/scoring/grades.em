## A second file in the same directory. Its names sit beside the other file's,
## with no qualification between them: `pass_mark` below is the one declared in
## `scores.em`.

func grade(score: Int): String {
    return "excellent" if score >= 8
    return "good" if score >= pass_mark
    return _needs_work()
}

## Private to this file, because its name starts with an underscore. No other
## file can reach it, so a helper never becomes part of the namespace by
## accident.
func _needs_work(): String {
    return "needs work"
}
