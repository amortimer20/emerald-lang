# Mistake: semicolon making an empty loop body (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake E.
var i = 0
while i < 3; {
    i += 1
}
