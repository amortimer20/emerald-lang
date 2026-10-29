# Mistake: custom error not extending Error (line 5). Source: carry-over from Java/C.
class BadScore {
    var message: String
}
raise BadScore("too high")
