using Ui
using Color = Ui.Console.Color

print(Console.Color.red)
print(Ui.Console.Color.green)

const favorite: Console.Color = Console.favorite()
print(favorite.describe())

const alias: Color = Color.red
print(alias)

const pair: Ui.Console.Pair = Console.Pair(1, 2)
print(pair.swapped())
print(Console.Pair.zero())

const deep: Console.Pair.Deep = Console.Pair.Deep("nested twice")
print(deep)
print(Console.Peeker().peek(Console()))
