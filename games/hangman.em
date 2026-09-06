class Hangman

static const MISSES_ALLOWED = 6

var secret: String
var guessed: Set<String>
var misses: Int

constructor(secret: String) {
    self.secret = secret
    self.guessed = [].to_set()
    self.misses = 0
}

# The word with every unguessed letter hidden. This is the whole display.
var masked: String {
    get {
        var shown: List<String> = []
        for letter in self.secret {
            shown.add(if self.guessed.contains?(letter) then letter else "_")
        }
        return shown.join(" ")
    }
}

var misses_left: Int {
    get { return Hangman.MISSES_ALLOWED - self.misses }
}

var won?: Bool {
    get {
        for letter in self.secret {
            return false unless self.guessed.contains?(letter)
        }
        return true
    }
}

var lost?: Bool {
    get { return self.misses >= Hangman.MISSES_ALLOWED }
}

var over?: Bool {
    get { return self.won? or self.lost? }
}

# Records the letter, and answers whether it was in the word.
func hit?(letter: String): Bool {
    self.guessed.add(letter)
    var hit = self.secret.contains?(letter)
    self.misses += 1 unless hit
    return hit
}

func already_tried?(letter: String): Bool {
    return self.guessed.contains?(letter)
}

func wrong_letters(): List<String> {
    return self.guessed.to_list().filter { g => not self.secret.contains?(g) }
}
