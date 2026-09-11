# A list that no binding holds cannot be seen again, so changing it would be
# lost immediately.

func starting_scores(): [Int] {
    return [0, 0]
}

starting_scores().append(10)
