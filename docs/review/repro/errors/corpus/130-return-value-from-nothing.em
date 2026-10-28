# Mistake: returning a value from a function declared to return Nothing (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake Q.
func greet(name: String): Nothing {
    return "Hello " + name
}
print(greet("Ava"))
