# Mistake: two parameters for a one-parameter block (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake I.
var nums = [1, 2, 3]
nums.each { i, n => print(i, n) }
