# Mistake: own function's result ignored (line 6). Source: Altadmri & Brown 2015 (Blackbox), mistake N.
func double(n: Int): Int {
    return n * 2
}
var x = 4
double(x)
print(x)
