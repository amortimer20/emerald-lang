const e = "\u{1B}"
assert Console.panel("x", color: Console.Color.blue) == "#{e}[34m┌───┐#{e}[39m\n#{e}[34m│#{e}[39m x #{e}[34m│#{e}[39m\n#{e}[34m└───┘#{e}[39m"
assert Console.panel(Console.red("x"), title: "Hi", color: Console.Color.blue).contains?("#{e}[31mx#{e}[39m")
assert Console.table([[Console.red("red"), "中"], ["a", "b"]]) == "┌─────┬────┐\n│ #{e}[31mred#{e}[39m │ 中 │\n│ a   │ b  │\n└─────┴────┘"
print("colored layout passed")
