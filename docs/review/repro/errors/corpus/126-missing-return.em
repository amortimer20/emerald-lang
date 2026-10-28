# Mistake: function with a return type that never returns (line 4). Source: Altadmri & Brown 2015 (Blackbox), mistake O; review brief list.
func square(n: Int): Int {
    var result = n * n
}
print(square(4))
