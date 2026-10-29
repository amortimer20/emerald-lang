# Section 5.3: "A NaN or infinite remainder operand produces NaN." Expected true on every line.
const infinity = 1e308 * 10
print((infinity % 2).nan?())
print((5 % infinity).nan?())
print((5 % -infinity).nan?())
print((-5 % infinity).nan?())
