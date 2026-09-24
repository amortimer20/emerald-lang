## Styled terminal output with Console.
##
## Console.green and friends wrap a String in ANSI styling; they are ordinary
## Strings themselves, so print, interpolation, and + all work on them
## unchanged. Whether they actually show color is one policy for the whole
## run, decided by the terminal, not by this program.
##
## Run it with `emerald run examples/console.em` to see it plain (redirected
## output stays unstyled), or `emerald run --color=always examples/console.em`
## to see it styled regardless of the terminal.

print(Console.green("Passed") + ": " + "3 tests")
print(Console.red("Failed") + ": " + "1 test")

## Console.style reaches backgrounds, bright colors, and combined attributes
## that the eight-color/four-style helpers above cannot.
print(Console.style("Warning", foreground: Console.Color.bright_yellow, bold: true))

## A style nests correctly inside another: the inner close reopens the
## surrounding one rather than falling back to the terminal's default.
print(Console.bold("Total: #{Console.green("20")} passed"))

## plain removes Console's own styling, regardless of the color policy —
## useful for logging or measuring text that was only styled for a terminal.
const styled = Console.underline("plain-checked")
print(Console.plain(styled))
