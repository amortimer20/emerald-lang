const e = "\u{1B}"

# The eight foreground helpers and four text styles each use one SGR layer.
assert Console.black("x") == "#{e}[30mx#{e}[39m"
assert Console.red("x") == "#{e}[31mx#{e}[39m"
assert Console.green("x") == "#{e}[32mx#{e}[39m"
assert Console.yellow("x") == "#{e}[33mx#{e}[39m"
assert Console.blue("x") == "#{e}[34mx#{e}[39m"
assert Console.magenta("x") == "#{e}[35mx#{e}[39m"
assert Console.cyan("x") == "#{e}[36mx#{e}[39m"
assert Console.white("x") == "#{e}[37mx#{e}[39m"
assert Console.bold("x") == "#{e}[1mx#{e}[22m"
assert Console.dim("x") == "#{e}[2mx#{e}[22m"
assert Console.italic("x") == "#{e}[3mx#{e}[23m"
assert Console.underline("x") == "#{e}[4mx#{e}[24m"

# An inner close reopens its enclosing foreground or text style.
assert Console.green("a #{Console.red("b")} c") == "#{e}[32ma #{e}[31mb#{e}[39m#{e}[32m c#{e}[39m"
assert Console.style("a #{Console.red("b")} c", background: Console.Color.blue) == "#{e}[44ma #{e}[31mb#{e}[39m c#{e}[49m"
assert Console.bold("a #{Console.dim("b")} c") == "#{e}[1ma #{e}[2mb#{e}[22m#{e}[1m c#{e}[22m"
assert Console.dim("a #{Console.bold("b")} c") == "#{e}[2ma #{e}[1mb#{e}[22m#{e}[2m c#{e}[22m"

# A reset in input also restores every enclosing layer.
assert Console.green("a #{e}[0mb") == "#{e}[32ma #{e}[0m#{e}[32mb#{e}[39m"

# The first requested layer is innermost: foreground, background, then styles.
assert Console.style("w", foreground: Console.Color.bright_yellow, background: Console.Color.blue, bold: true) == "#{e}[1m#{e}[44m#{e}[93mw#{e}[39m#{e}[49m#{e}[22m"
assert Console.style("x", foreground: Console.Color.bright_cyan, background: Console.Color.bright_yellow) == "#{e}[103m#{e}[96mx#{e}[39m#{e}[49m"
assert Console.style("plain") == "plain"

print("color helpers passed")
