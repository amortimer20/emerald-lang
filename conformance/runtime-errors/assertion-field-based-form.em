# Section 15.1: assertion failures keep the field-based form, so building the failure
# never runs the program's own `to_string`.
struct Score with Textual {
    const points: Int

    @override
    func to_string(): String {
        print("to_string ran")
        return "#{self.points} points"
    }
}

const score = Score(points: 3)
print(score)
assert score == Score(points: 4), "the score should be four"
