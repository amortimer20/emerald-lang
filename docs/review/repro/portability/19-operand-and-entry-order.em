# 5.2 orders "function arguments and other ordered expression lists" and
# compound assignment. Binary operands (including right-associative `**`),
# dictionary key/value interleaving, and plain index assignment are not named.
func t(label: String, value: Int): Int {
    print(label)
    return value
}
const sum = t("left of +", 1) + t("right of +", 2)
const power = t("base", 2) ** t("exponent", 3)
const same = t("left of ==", 1) == t("right of ==", 1)
const entries = [t("key 0", 0): t("value 0", 0), t("key 1", 1): t("value 1", 1)]
var list = [0, 0]
list[t("index", 0)] = t("value", 1)
