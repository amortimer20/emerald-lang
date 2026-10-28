# Mistake: variable assigned on only one branch (line 7). Source: guide docs/language/core.md; rewrite-context 17.1.
var score = 40
var grade: String
if score >= 50 {
    grade = "pass"
}
print(grade)
