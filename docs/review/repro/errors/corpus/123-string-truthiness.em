# Mistake: using a String as a condition (line 3). Source: carry-over from Python.
var name = input("Name: ")
if name {
    print("Hi " + name)
}
