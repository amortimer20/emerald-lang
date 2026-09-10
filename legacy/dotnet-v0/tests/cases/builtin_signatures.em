## The built-in methods have signatures now, so the standard library is checked the same
## way a program is. Every one of these was accepted before.
print("hello".replace("l", "L"))
print("hello".starts_with?("he"))
print(7.clamp(1, 5))
print("a,b,c".split(",").join("-"))
print(3.between?(1, 5))
print(Math.pow(2.0, 3.0))

3.times { print("times") }
1.upto(3) { i => print(i) }

## Bare access is a zero-argument call, and still works where nothing is needed.
print("hi".count())
print(7.abs())
print((1..3).count())
print(Math.pi())
