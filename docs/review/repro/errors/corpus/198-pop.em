# Mistake: .pop to remove the last (line 3). Source: carry-over from Python; carry-over from JavaScript.
var stack = [1, 2, 3]
var top = stack.pop()
print(top)
