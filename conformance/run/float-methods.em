# Section 9.3's Float vocabulary, including widening, signed zero, NaN, and
# infinity and their type-level constants.

const nan = Float.nan
const infinity = Float.infinity

print((-3.5).abs(), (-0.0).abs())
print(5.5.clamp(1, 3), (-2.5).clamp(1.0, 3.0), 2.5.clamp(1, 3))
print(1.0.between?(1, 3), 3.0.between?(1, 3), 4.0.between?(1, 3), nan.between?(1, 3))
print(0.0.zero?(), (-0.0).zero?(), 1.0.positive?(), (-1.0).negative?())
print((-2.1).floor(), (-2.1).ceil(), (-2.5).round(), 2.5.round())
print((-2.9).truncate(), (-2.9).to_int())
print(12.345.round_to(2), (-12.345).round_to(2), 125.0.round_to(-1))
print(1.25.round_to(400), (-1.25).round_to(-400))
print(1.0.finite?(), infinity.finite?(), infinity.infinite?(), nan.nan?())
print(nan.finite?(), nan.infinite?(), infinity.nan?())
print((-infinity).negative?(), (-infinity).abs().positive?())
print(nan.positive?(), nan.negative?(), nan.zero?(), nan.abs().nan?(), nan.clamp(0, 1).nan?())
print(1.5.clamp(-infinity, infinity), infinity.round_to(2), nan.round_to(-2).nan?())
print(2.5.floor().type_name, 2.5.round_to(0).type_name)
print(Float.nan.type_name, Float.infinity.type_name)

var evaluations = 0
func counted(value: Float): Float {
    evaluations += 1
    return value
}
print(counted(2.5).clamp(counted(1), counted(3)), evaluations)
