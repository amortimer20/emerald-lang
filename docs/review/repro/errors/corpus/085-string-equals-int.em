# Mistake: String compared with Int using == (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake B (equality across types).
var answer = input("2 + 2 = ")
if answer == 4 {
    print("correct")
}
