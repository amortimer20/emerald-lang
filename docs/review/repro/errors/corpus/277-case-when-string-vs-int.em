# Mistake: case arms of the wrong type (line 4). Source: Kohn 2019 (The Error Behind the Message, Python novices).
var choice = input("1 or 2? ")
case choice {
    when 1 {
        print("one")
    }
    when 2 {
        print("two")
    }
}
