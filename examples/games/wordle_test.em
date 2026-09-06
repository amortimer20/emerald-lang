# Every one of these is a case a naive scorer gets wrong.

func marks_of(secret: String, guess: String): String {
    return Wordle(secret).score(guess).map { m => m.name.chars()[0] }.join("")
}

@test
func greens_an_exact_match() {
    assert WordleTest.marks_of("crane", "crane") == "HHHHH"
}

@test
func greys_a_letter_that_is_not_there() {
    assert WordleTest.marks_of("crane", "boggy") == "MMMMM"
}

@test
func yellows_a_letter_in_the_wrong_place() {
    assert WordleTest.marks_of("crane", "nacre") == "PPPPH"
}

# The one that matters. ABBEY holds two Bs; the exact match at position three claims
# one, so only one is left over — the leading B is yellow and the fourth is grey.
@test
func spends_each_repeated_letter_once() {
    assert WordleTest.marks_of("abbey", "bobby") == "PMHMH"
}

# A repeat in the guess that the secret has only once: the first gets it, the rest do not.
@test
func gives_a_repeat_to_the_leftmost_guess() {
    assert WordleTest.marks_of("maker", "eerie") == "PMPMM"
}

# And an exact match later in the word still outranks an earlier near-miss.
@test
func lets_a_later_exact_match_take_the_letter() {
    assert WordleTest.marks_of("added", "dread") == "PMPPH"
}

@test
func counts_a_try_and_ends_at_six() {
    var game = Wordle("crane")
    assert game.tries_left == 6
    for i in 1..6 {
        game.submit("boggy")
    }
    assert game.tries_left == 0
    assert game.over?
    assert not game.won?
}

@test
func ends_early_on_a_win() {
    var game = Wordle("crane")
    game.submit("slate")
    game.submit("crane")
    assert game.won?
    assert game.over?
    assert game.tries_left == 4
}

# A letter must never lose ground: green once is green for good.
@test
func keeps_the_best_news_about_a_letter() {
    var game = Wordle("crane")
    game.submit("nacre")
    game.submit("crane")
    var news = game.letter_news()
    assert news["c"].or(Mark.MISS) == Mark.HIT
    assert news["b"] == nothing
}
