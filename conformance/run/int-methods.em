# Section 9.3's first numeric vocabulary, including signs, zero, and the
# asymmetric edge of Int.

print((-7).abs())
print(5.clamp(1, 3), (-2).clamp(1, 3), 2.clamp(1, 3))
print(1.between?(1, 3), 3.between?(1, 3), 4.between?(1, 3))
print(0.zero?(), 1.positive?(), (-1).negative?())
print((-4).even?(), (-3).odd?(), 12.multiple_of?(-3), 0.multiple_of?(7))
print(0.digits(), 907.digits(), (-9223372036854775808).digits())
print(54.gcd(24), (-54).gcd(24), 0.gcd(0), (-9223372036854775808).gcd(2))
print(6.lcm(8), (-6).lcm(8), 0.lcm(8))
print(0.factorial(), 1.factorial(), 5.factorial(), 20.factorial())
print(42.to_float(), 42.to_float().type_name)

var evaluations = 0
func counted(value: Int): Int {
    evaluations += 1
    return value
}
print(counted(54).gcd(counted(24)), evaluations)
