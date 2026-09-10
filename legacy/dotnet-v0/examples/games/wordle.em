class Wordle

static const LENGTH = 5
static const TRIES = 6

var secret: String
var attempts: List<Attempt>

constructor(secret: String) {
    self.secret = secret
    self.attempts = []
}

# The rule that separates a real Wordle from a naive one is what happens to a repeated
# letter. Guessing SPEED against ERASE must green the second E and gray the first: the
# word holds two Es, one is already spoken for by the exact match, so only one is left
# to color. Counting the leftovers is the whole algorithm.
func score(guess: String): List<Mark> {
    var wanted = self.secret.chars()
    var given = guess.chars()

    var marks: List<Mark> = []
    var spare: Dictionary<String, Int> = [:]

    # Exact positions first, and every letter they do not claim is a leftover.
    for i in 0..(Wordle.LENGTH - 1) {
        if given[i] == wanted[i] {
            marks.add(Mark.HIT)
        }
        else {
            marks.add(Mark.MISS)
            spare[wanted[i]] = spare[wanted[i]].or(0) + 1
        }
    }

    # Then the leftovers, left to right, until they run out.
    for i in 0..(Wordle.LENGTH - 1) {
        continue if marks[i] == Mark.HIT
        var letter = given[i]
        continue unless spare[letter].or(0) > 0
        marks[i] = Mark.PRESENT
        spare[letter] -= 1
    }

    return marks
}

func submit(guess: String): List<Mark> {
    var marks = self.score(guess)
    self.attempts.add(Attempt(guess, marks))
    return marks
}

var tries_left: Int {
    get { return Wordle.TRIES - self.attempts.count() }
}

var won?: Bool {
    get { return self.attempts.any? { a => a.word == self.secret } }
}

var over?: Bool {
    get { return self.won? or self.tries_left <= 0 }
}

# The best news each letter has brought so far, for the keyboard display. A letter that
# was green once must not go back to yellow because a later guess put it elsewhere.
func letter_news(): Dictionary<String, Mark> {
    var news: Dictionary<String, Mark> = [:]

    for attempt in self.attempts {
        var letters = attempt.word.chars()

        for i in 0..(Wordle.LENGTH - 1) {
            var letter = letters[i]
            var known = news[letter]

            if known == nothing or attempt.marks[i].better_than?(known.or(Mark.MISS)) {
                news[letter] = attempt.marks[i]
            }
        }
    }

    return news
}
