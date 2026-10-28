# Mistake: remove(0) meaning remove the first item (line 3). Source: carry-over from Python (remove vs pop).
var names = ["Ava", "Bo"]
names.remove(0)
print(names)
