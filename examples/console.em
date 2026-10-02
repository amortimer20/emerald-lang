# A small terminal program using Console's styling, layout, and prompts.
#
# Run it with `emerald run examples/console.em` for plain output, or add
# `--color=always` to see the ANSI styling even when output is redirected.

struct Score {
    const name: String
    const points: Int
}

const scores = [Score("Ada", 120), Score("Grace", 95), Score("Hopper", 88)]
print(Console.panel("Welcome to the score board!", title: "Emerald"))
print(Console.table(scores))
print(Console.green("All three players are ready."))

const player = Console.ask("What's your name?", default: "Ada")
const play_again = Console.confirm("Play again?", default: true)
if play_again {
    print("Good luck, #{player}!")
}
