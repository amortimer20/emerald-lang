const name = Console.ask("Name?", default: "Ada")
const age = Console.ask_int("Age?", minimum: 0, maximum: 150)
const level = Console.choose("Level", ["Easy", "Hard"])
const toppings = Console.choose_many("Toppings", ["Cheese", "Olives"])
const again = Console.confirm("Again?", default: true)
print(name, age, level, toppings, again)

const number = Console.ask_float("Ratio?", minimum: 0.0, maximum: 2.0)
print(number)
