# Parentheses that change meaning survive; parentheses that do not are
# dropped, since grouping itself leaves no trace once parsed and the
# formatter has to re-derive which ones are load-bearing.
const a = (1 + 2) * 3
const b = 1 + 2 * 3
const c = (1 + 2) ** 2
const d = 2 ** (3 ** 4)
const e = (2 ** 3) ** 4
const f = -(1 + 2)
const g = not (true and false)
const h = (-9223372036854775808).digits()
# A `-` written against a number is part of it, so these need no parentheses,
# except before `**`, which the sign does not bind across. A `-` with a space
# after it negates everything that follows, so it keeps them.
const i = (-3).abs()
const j = (-2.5).round()
const k = (-2) ** 2
const l = - 3.abs()
const m = -(-3)
const n = (- 9223372036854775808).digits()
