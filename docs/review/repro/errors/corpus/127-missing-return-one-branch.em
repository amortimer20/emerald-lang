# Mistake: a branch that falls off without returning (line 9). Source: Altadmri & Brown 2015 (Blackbox), mistake O.
func sign(n: Int): String {
    if n > 0 {
        return "positive"
    }
    else if n < 0 {
        return "negative"
    }
}
print(sign(0))
