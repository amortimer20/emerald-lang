# Number guessing game

const MAX = 100

var secret  = random(1, MAX)
var guesses = 0
var done    = false

print("I'm thinking of a number between 1 and #{MAX}.")

while not done {
    var guess = read_line("Your guess: ").to_int_or(0)
    guesses += 1

    if guess < secret {
        print("Too low.")
    }
    else if guess > secret {
        print("Too high.")
    }
    else {
        print("You got it in #{guesses} guesses!")
        done = true
    }
}
