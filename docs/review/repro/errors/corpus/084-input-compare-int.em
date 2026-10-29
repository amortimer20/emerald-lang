# Mistake: comparing input text with a number (line 3). Source: Kohn 2019 (The Error Behind the Message, Python novices).
var age = input("How old are you? ")
if age >= 18 {
    print("adult")
}
