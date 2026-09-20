# Section 14.1: a bare top-level `return` ends the program; it cannot return
# a value, and everything after an unconditional one is unreachable exactly
# as it would be after any other early exit.
print("first")
return
return "value"
