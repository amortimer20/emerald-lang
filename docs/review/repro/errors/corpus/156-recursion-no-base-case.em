# Mistake: recursion without a base case (line 4). Source: McCall & Kolling 2019 (meaningful categories of novice errors); Kohn 2019 (The Error Behind the Message, Python novices) (RecursionError).
func count_down(n: Int) {
    print(n)
    count_down(n - 1)
}
count_down(3)
