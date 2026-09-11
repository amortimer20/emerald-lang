# Section 5.1's string forms. Double quotes process escapes and interpolation,
# single quotes are raw, and `\u{...}` writes a character by its code point.

var count = 3
print("There are #{count} gems.")
print("\#{count} is literal, a tab:\t|, a quote: \", a backslash: \\")
print('C:\Users\student\game', '\d+')
print("caf\u{E9} and cafe\u{301} look the same")

# Any value can be interpolated, displayed as `print` would display it, and an
# interpolation may hold another string with its own.
print("#{count / 2} #{count > 2} #{[1, 2]} #{"inner #{count + 1}"}")

# Inside a list, strings are quoted, so the list's structure stays visible.
print(["Ava", "a, b", "say \"hi\""])
