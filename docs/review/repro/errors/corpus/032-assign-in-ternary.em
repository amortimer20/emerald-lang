# Mistake: = instead of == in an if expression (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake A.
var n = 4
var kind = if n % 2 = 0 then "even" else "odd"
print(kind)
