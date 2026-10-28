# Mistake: calling trim() and ignoring the result (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake N.
var name = "  Ava  "
name.trim()
print("[" + name + "]")
