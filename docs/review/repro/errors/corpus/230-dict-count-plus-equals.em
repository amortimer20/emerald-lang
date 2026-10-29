# Mistake: += on a missing dictionary entry (line 4). Source: Kohn 2019 (The Error Behind the Message, Python novices) (KeyError).
var counts: Dict[String, Int] = []
for word in ["a", "b", "a"] {
    counts[word] += 1
}
print(counts)
