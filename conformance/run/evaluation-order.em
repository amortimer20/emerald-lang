# Section 5.2: binary operands evaluate left to right whatever the operator's associativity;
# a dictionary literal evaluates each key, then its value, entry by entry; a plain indexed
# assignment evaluates its receiver and index, then the right side, then checks the index,
# while compound assignment checks first; the write goes to the binding's value at that moment.
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
print(sum, power, same, entries, list)

var xs = [1]
try {
    xs[5] += t("compound right side", 1)
}
catch error {
    print(error.message)
}
try {
    xs[5] = t("plain right side", 1)
}
catch error {
    print(error.message)
}

var ys = [1, 2, 3]
func replace_ys(): Int {
    ys = [7]
    return 9
}
ys[0] += replace_ys()
print(ys)
