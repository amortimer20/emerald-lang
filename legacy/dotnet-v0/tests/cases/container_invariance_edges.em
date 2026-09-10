## What invariance deliberately still allows.

# An element type the checker never pinned down fits anything: there is nothing in an
# empty container to be wrong about.
var a: List<Int> = []
var d: Dictionary<String, Int> = [:]
var s: Set<Int> = [].to_set()

# Exact matches, nested ones included.
var floats: List<Float> = [1.0, 2.0]
var grid: List<List<Int>> = [[1], [2]]

# A pair stays covariant, because nothing can be written into one after it is built --
# there is no second name through which to spoil it.
class Animal { }
class Dog extends Animal { }
var paired: Pair<Animal, Int> = Pair(Dog(), 1)

a.add(1)
d.set("k", 2)
print("#{a} #{d} #{s.count()} #{floats} #{grid} #{paired.second()}")
