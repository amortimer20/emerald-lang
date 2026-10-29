# Mistake: = instead of == in a while (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake A.
var done = false
while done = false {
    done = true
}
