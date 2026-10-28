# Mistake: adopting a trait without its member (line 5). Source: Altadmri & Brown 2015 (Blackbox), mistake R.
trait Shape {
    func area(): Float
}
struct Square with Shape {
    var side: Float
}
print(Square(2.0))
