# Wordle without color. The web game says everything in green, yellow and gray, which
# a terminal cannot be relied on to show — so the marks go on a line of their own under
# the word, and what is known about each letter is spelled out in words.

func symbol(mark: Mark): String {
    return if mark == Mark.HIT then "#" else if mark == Mark.PRESENT then "+" else "."
}

func spaced(letters: List<String>): String {
    return "   " + letters.join(" ")
}

func board(game: Wordle) {
    print()
    for attempt in game.attempts {
        print(WordleGame.spaced(attempt.word.upper().chars()))
        print(WordleGame.spaced(attempt.marks.map { m => WordleGame.symbol(m) }))
        print()
    }
}

# Which letters are known to be where. This is the part a color display gives you for
# free and a plain one has to say out loud.
func news(game: Wordle) {
    var found = WordleGame.letters(game, Mark.HIT)
    var somewhere = WordleGame.letters(game, Mark.PRESENT)
    var ruled_out = WordleGame.letters(game, Mark.MISS)

    print("   in place:   " + (if found.empty?() then "-" else found.join(" ")))
    print("   elsewhere:  " + (if somewhere.empty?() then "-" else somewhere.join(" ")))
    print("   ruled out:  " + (if ruled_out.empty?() then "-" else ruled_out.join(" ")))
}

func letters(game: Wordle, mark: Mark): List<String> {
    var news = game.letter_news()
    return news.keys().filter { k => news[k].or(Mark.MISS) == mark }.sort()
}

func a_word?(text: String): Bool {
    return false unless text.count() == Wordle.LENGTH
    for letter in text {
        return false unless HangmanGame.ALPHABET.contains?(letter)
    }
    return true
}

func play() {
    Text.banner("Wordle")
    print("Five letters, six tries.  # right place   + wrong place   . not in the word")

    var words = Words.wordle()
    var game = Wordle(words[random(0, words.count() - 1)])

    while not game.over? {
        WordleGame.board(game)
        WordleGame.news(game) unless game.attempts.empty?()

        var guess = read_line("   #{game.tries_left} left> ").trim().lower()

        unless WordleGame.a_word?(guess) {
            print("   Five letters, please.")
            continue
        }

        game.submit(guess)
    }

    WordleGame.board(game)
    print(if game.won?
          then "   Got it in #{game.attempts.count()}."
          else "   Out of tries. The word was #{game.secret.upper()}.")
}
