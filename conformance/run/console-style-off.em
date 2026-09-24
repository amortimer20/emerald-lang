# Color defaults off for ordinary execution. A project declaration shadows the
# bare built-in name, which remains available through Emerald.Console.
class Console { }

assert Emerald.Console.black("x") == "x"
assert Emerald.Console.red("x") == "x"
assert Emerald.Console.green("x") == "x"
assert Emerald.Console.yellow("x") == "x"
assert Emerald.Console.blue("x") == "x"
assert Emerald.Console.magenta("x") == "x"
assert Emerald.Console.cyan("x") == "x"
assert Emerald.Console.white("x") == "x"
assert Emerald.Console.bold("x") == "x"
assert Emerald.Console.dim("x") == "x"
assert Emerald.Console.italic("x") == "x"
assert Emerald.Console.underline("x") == "x"
assert Emerald.Console.style("x", foreground: Emerald.Console.Color.bright_red, background: Emerald.Console.Color.bright_blue, bold: true, dim: true, italic: true, underline: true) == "x"
assert Emerald.Console.style("plain") == "plain"
print(Emerald.Console.green("unstyled"))
