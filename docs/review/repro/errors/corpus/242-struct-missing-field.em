# Mistake: constructing a struct with a field missing (line 6). Source: Altadmri & Brown 2015 (Blackbox), mistake I.
struct Point {
    var x: Int
    var y: Int
}
var p = Point(1)
print(p)
