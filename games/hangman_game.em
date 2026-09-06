# The screen half of Hangman. The rules live in Hangman, which knows nothing about
# printing — that split is what lets hangman_test.em play whole games without a person.

const ALPHABET = "abcdefghijklmnopqrstuvwxyz"

# Six wrong guesses, six body parts, one line of code each.
func picture(misses: Int): String {
    var head  = if misses >= 1 then "O" else " "
    var torso = if misses >= 2 then "|" else " "
    var left  = if misses >= 3 then "/" else " "
    var right = if misses >= 4 then "\\" else " "
    var lleg  = if misses >= 5 then "/" else " "
    var rleg  = if misses >= 6 then "\\" else " "

    var rows = [
        "  +---+",
        "  |   |",
        "  " + head + "   |",
        " " + left + torso + right + "  |",
        " " + lleg + " " + rleg + "  |",
        "======="
    ]
    return rows.join("\n")
}

func a_letter?(text: String): Bool {
    return text.count() == 1 and HangmanGame.ALPHABET.contains?(text)
}

func show(game: Hangman) {
    print()
    print(HangmanGame.picture(game.misses))
    print()
    print("   " + game.masked)
    print()

    var wrong = game.wrong_letters()
    print("   missed: " + (if wrong.empty?() then "none" else wrong.join(" ")))
    print("   #{game.misses_left} wrong guess(es) left")
}

func play() {
    Text.banner("Hangman")
    print("Guess the word one letter at a time. Six misses and you hang.")

    var words = Words.hangman()
    var game = Hangman(words[random(0, words.count() - 1)])

    while not game.over? {
        HangmanGame.show(game)
        var letter = read_line("   letter> ").trim().lower()

        unless HangmanGame.a_letter?(letter) {
            print("   That is not a single letter.")
            continue
        }

        if game.already_tried?(letter) {
            print("   You have tried #{letter} already.")
            continue
        }

        print(if game.hit?(letter) then "   Yes, there is a #{letter}." else "   No #{letter}.")
    }

    HangmanGame.show(game)
    print()
    print(if game.won? then "You got it: #{game.secret}" else "Hanged. The word was #{game.secret}.")
}
