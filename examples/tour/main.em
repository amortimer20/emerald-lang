# A tour of what v0 supports

5.times { print("hi") }

1.upto(3) { i => print("up #{i}") }
3.downto(1) { i => print("down #{i}") }

for i in 1..3 {
    print("for #{i}")
}

print(7.even?)
print(7.between?(1, 10))
print(42.clamp(1, 10))

var status = if 95 >= 90 then "A" else "B"
print("grade: #{status}")

print("hello".upper)
print("hello".length)
print("olleh".reverse)

func double(n: Int): Int {
    return n * 2
}

print(double(21))
print("printed via modifier") if 3 > 2

var total = 0
(1..4).each { n => total += n }
print("sum: #{total}")
