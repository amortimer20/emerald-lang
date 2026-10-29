# Mistake: comparing a Bool to the text true in quotes (line 3). Source: Kohn 2019 (The Error Behind the Message, Python novices).
var ready = true
if ready == "true" {
    print("go")
}
