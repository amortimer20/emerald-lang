# Mistake: returning a String from an Int function (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake Q.
func score(): Int {
    return "100"
}
print(score())
