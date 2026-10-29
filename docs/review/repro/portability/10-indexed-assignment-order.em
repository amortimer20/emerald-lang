# 5.2 orders compound assignment (target checked before the right side) but
# says nothing for plain `a[i] = v`, nor what happens when the right side
# replaces the list being assigned into.
func t(label: String, value: Int): Int {
    print(label)
    return value
}
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
