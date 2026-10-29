# Probe: Dict, Set, frequencies, group_by order (spec: insertion order).
var d: Dict[String, Int] = []
for i in 0..300 {
    d["k" + ((i * 7919) % 1000).to_string()] = i
}
for i in 0..300 {
    if i % 3 == 0 {
        d.remove("k" + ((i * 7919) % 1000).to_string())
    }
}
d["k7"] = -1
d["zz"] = -2
print(d.keys().join(","))
var s: Set[Float] = []
for i in 0..200 {
    s.add((i * 37 % 101) * 0.1)
}
s.remove(0.0)
s.add(-0.0)
print(s)
const words = "the quick brown fox jumps over the lazy dog then the fox naps 東京 Ünïcödé é é".split(" ")
print(words.frequencies())
# group_by is left out: it aborts on four or more items in one group (see crash/group-by-count.em).
var t: Set[String] = []
for w in words {
    t.add(w.upper())
}
const extra: Set[String] = ["A", "Z", "THE"]
const some: Set[String] = ["FOX", "THE", "DOG"]
print(t, t.union(extra), t.intersection(some))
const mixed: Dict[Int, String] = []
print(d.map_values { v => v * 2 }.entries().take(5))
var big: Dict[Int, Int] = []
for i in 0..5000 {
    big[(i * 2654435761) % 1000003] = i
}
var acc = 0
var index = 0
for (k, v) in big.entries() {
    acc = (acc * 31 + k + v * index) % 1000000007
    index += 1
}
print(acc)
