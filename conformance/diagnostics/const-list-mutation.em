# Section 4.3: `const` freezes a value. For a list, changing the contents and
# replacing it leave the same observable result, so both are forbidden.

const players = [1, 2]
players.append(3)
