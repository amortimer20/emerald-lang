# Section 8.6: the non-bang forms work on a `const`; the bang forms need a changeable list.
const scores = [3, 1, 2, 1]
print(scores.sort(), scores.reverse(), scores.unique())
scores.sort!()
scores.reverse!()
scores.unique!()
scores.shuffle!()
