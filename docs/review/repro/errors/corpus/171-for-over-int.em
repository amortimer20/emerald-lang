# Mistake: for over an Int count (line 3). Source: carry-over from Python; Kohn 2019 (The Error Behind the Message, Python novices).
var names = ["Ava", "Bo"]
for i in names.count {
    print(names[i])
}
