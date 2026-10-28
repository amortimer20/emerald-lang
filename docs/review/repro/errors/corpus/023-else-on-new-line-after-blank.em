# Mistake: stray code between } and else (line 7). Source: Altadmri & Brown 2015 (Blackbox), mistake C.
var x = 5
if x > 3 {
    print("big")
}
print("checked")
else {
    print("small")
}
