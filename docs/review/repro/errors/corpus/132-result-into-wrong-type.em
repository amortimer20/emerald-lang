# Mistake: function result into a wrongly typed variable (line 5). Source: Altadmri & Brown 2015 (Blackbox), mistake Q.
func name(): String {
    return "Ava"
}
var n: Int = name()
print(n)
