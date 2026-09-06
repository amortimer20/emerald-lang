# The rules are a class with no printing in it, so a test can play a whole game.

@test
func hides_every_letter_at_the_start() {
    assert Hangman("cat").masked == "_ _ _"
}

@test
func reveals_every_copy_of_a_letter_at_once() {
    var game = Hangman("banana")
    assert game.hit?("a")
    assert game.masked == "_ a _ a _ a"
}

@test
func counts_a_miss_and_leaves_the_word_alone() {
    var game = Hangman("cat")
    assert not game.hit?("z")
    assert game.misses == 1
    assert game.masked == "_ _ _"
}

@test
func ends_when_every_letter_is_found() {
    var game = Hangman("cat")
    for letter in ["c", "a", "t"] {
        game.hit?(letter)
    }
    assert game.won?
    assert game.over?
    assert not game.lost?
}

@test
func hangs_after_six_misses() {
    var game = Hangman("cat")
    for letter in ["b", "d", "e", "f", "g", "h"] {
        game.hit?(letter)
    }
    assert game.lost?
    assert game.misses_left == 0
}

@test
func remembers_a_letter_that_was_already_tried() {
    var game = Hangman("cat")
    game.hit?("z")
    assert game.already_tried?("z")
    assert not game.already_tried?("q")
}

# A repeated wrong guess must not cost a second life. The game loop refuses it, but the
# rules should not depend on the loop being careful.
@test
func lists_each_wrong_letter_once() {
    var game = Hangman("cat")
    game.hit?("z")
    game.hit?("z")
    assert game.wrong_letters().count() == 1
}

@test
func draws_the_whole_body_at_six() {
    assert HangmanGame.picture(6).contains?("/ \\")
    assert HangmanGame.picture(0).contains?("O") == false
}
