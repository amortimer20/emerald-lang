# Program: Number Guessing Game
# Author: Anthony Mortimer

print("### Number Guessing Game 2026 ###")

var bottom_number = read_line("Enter your starting number: ").to_int
var top_number = read_line("Enter your top number: ").to_int

if bottom_number >= top_number {
    print("Error: Invalid number range. Exiting...")
    exit()
}

var secret_number = random(bottom_number, top_number)
var tries = 0
var guess = -1

until secret_number == guess {
    guess = read_line("Enter your guess between #{bottom_number} and #{top_number}: ").to_int()
    tries += 1

    if guess == secret_number {
        print("You win! It took you #{tries} tries!")
    }
    else if guess > secret_number {
        print("Wrong! Too high!")
    }
    else {
        print("Wrong! Too low!")
    }
}
