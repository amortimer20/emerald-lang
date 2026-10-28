# Mistake: reassigning a const (line 3). Source: review brief list; guide docs/language/core.md.
const limit = 10
limit = 20
print(limit)
