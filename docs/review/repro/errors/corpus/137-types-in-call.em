# Mistake: writing types in the call (line 5). Source: Altadmri & Brown 2015 (Blackbox), mistake P.
func square(n: Int): Int {
    return n * n
}
print(square(n: Int))
