#!/usr/bin/env bash
# The games in examples/games/ are the first programs written in Emerald that are programs
# rather than demonstrations of a feature. They are checked two ways: the rules have their
# own @test functions, and each game is played through to the end with scripted input.
#
# The second half matters because the rules and the screen are deliberately separate. A
# test can prove Wordle scores SPEED against ERASE correctly and still not notice that
# nothing ever prints it.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
emerald="$root/src/Emerald/bin/Debug/net10.0/Emerald.dll"
games="$root/examples/games"

if ! dotnet build "$root/src/Emerald" -v q --nologo -p:UseAppHost=false >/dev/null 2>&1; then
    echo "build failed"; exit 1
fi

fail=0
ok()  { echo "  OK   $1"; }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# The rules, which have no input and no output.
out="$(dotnet "$emerald" test "$games" 2>&1)"
grep -q "all passing" <<<"$out" && ok "game rules pass" || { bad "game rules pass"; echo "$out" | tail -20; }

# Each game played to the end. The words are chosen at random, so the input cannot aim
# at a particular one — it has to be enough letters to finish either way.
play() {
    local name="$1" input="$2" expect="$3"
    local got
    got="$(printf '%b' "$input" | dotnet "$emerald" run "$games/main.em" 2>&1)"

    if [[ $? -ne 0 ]]; then
        bad "$name ran"; echo "$got" | tail -5; return
    fi
    grep -q "$expect" <<<"$got" && ok "$name finished" || { bad "$name finished"; echo "$got" | tail -8; }
}

# Every letter of the alphabet: the word is found or the drawing is, either way it ends.
play "hangman" "1\n$(printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np\nq\nr\ns\nt\nu\nv\nw\nx\ny\nz\n')q\n" \
     "The word was\|You got it"

# Six guesses is the most Wordle can take, so six is always enough to end it.
play "wordle" "2\ncrane\nslate\nadieu\npilot\nghost\nflick\nq\n" "Out of tries\|Got it in"

# Nine squares, offered in order; the ones already taken are refused and the rest fill up.
play "tictactoe" "3\n1\n2\n3\n4\n5\n6\n7\n8\n9\nq\n" "Emerald wins\|A draw\|You win"

# Bad input must not end the program - a game a typo can kill is not finished.
play "bad input" "x\n9\n\nq\n" "Type 1, 2, 3, or q."

echo
(( fail == 0 )) && echo "games correct" || { echo "$fail game check(s) failed"; exit 1; }
