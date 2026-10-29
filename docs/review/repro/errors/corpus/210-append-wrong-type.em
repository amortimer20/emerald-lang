# Mistake: appending a String to List[Int] (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake I.
var scores = [1, 2]
scores.append("3")
print(scores)
