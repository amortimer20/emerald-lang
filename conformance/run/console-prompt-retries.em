# A bad answer repeats only the last line of a choice prompt: the options are
# shown once. Non-finite numbers are not numbers a person meant to type.
const level = Console.choose("Level", ["Easy", "Hard"])
const toppings = Console.choose_many("Toppings", ["Cheese", "Olives"])
const ratio = Console.ask_float("Ratio?")
const agree = Console.confirm("Agree?")
print(level, toppings, ratio, agree)
