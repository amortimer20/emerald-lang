# 8.5 "a list displays the way it is written"; 15.2 strings in a collection are
# "quoted, with escapes where needed". `#{` is not escaped, so the displayed
# literal would interpolate, and control characters other than \n \t \r \0 go
# out raw (pipe through `od -c` to see the BEL and ESC bytes).
const x = 5
print(["\#{x}", "#{x}"])
print(["bell\u{7}", "escape\u{1b}[31m", "delete\u{7f}"])
