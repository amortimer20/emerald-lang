# Mistake: semicolon at the end of a function header (line 2). Source: Altadmri & Brown 2015 (Blackbox), mistake K.
func square(n: Int): Int;
{
    return n * n
}
print(square(3))
