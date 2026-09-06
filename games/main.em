# Three games, one project. Every .em file beside this one is part of it, so there is
# nothing to import — the menu just calls them.
#
#   emerald run games/main.em      play
#   emerald test games             check the rules

Text.banner("Emerald Games")

var playing = true

while playing {
    print()
    print("   1  Hangman      guess the word before the drawing finishes")
    print("   2  Wordle       five letters, six tries")
    print("   3  Tic-tac-toe  against a player that cannot be beaten")
    print("   q  quit")

    var choice = read_line("\n   choose> ").trim().lower()

    if choice == "1" {
        HangmanGame.play()
    }
    else if choice == "2" {
        WordleGame.play()
    }
    else if choice == "3" {
        TicTacToeGame.play()
    }
    else if choice == "q" or choice == "quit" {
        playing = false
    }
    else {
        print("   Type 1, 2, 3, or q.")
    }
}

print()
print("Thanks for playing.")
