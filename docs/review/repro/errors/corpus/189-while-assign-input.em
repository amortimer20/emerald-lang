# Mistake: assignment inside a while condition (line 3). Source: carry-over from Java/C (while ((line = read()) != null)).
var line = ""
while (line = input("> ")) != "quit" {
    print(line)
}
