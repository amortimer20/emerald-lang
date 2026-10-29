# Probe: transcendental Math functions at many inputs, printed at full precision.
var inputs = [0.0, -0.0, 1e-300, 5e-324, 0.5, 1.0, 2.0, 3.0, 10.0, 100.0, 1e6, 1e10, 1e22, 1e100, 1e300, -1.5, -7.25, 0.7853981633974483, 1.5707963267948966, 3.141592653589793, 6.283185307179586, 710.0, 1e-10]
for i in 1..200 {
    inputs.append(i * 0.37 - 30.0)
    inputs.append(1.1 ** i)
}
for x in inputs {
    print(x, Math.sin(x), Math.cos(x), Math.tan(x))
    print("  ", Math.arc_sin(x / 1000), Math.arc_cos(x / 1000), Math.arc_tan(x), Math.arc_tan2(x, 0.3), Math.arc_tan2(-1.7, x))
    print("  ", Math.natural_log(x), Math.log10(x), Math.log(x, 3), Math.log(x, 2), Math.log(x, 10))
    print("  ", Math.power(x, 0.5), Math.power(1.0001, x), Math.power(x, 3.3), Math.power(2.0, x / 7), x ** 1.7, x.square_root(), x.to_radians(), x.to_degrees())
}
print(Math.power(-8.0, 1.0 / 3), Math.power(0.0, -1.0), Math.power(-0.0, -1.0), Math.power(Float.nan, 0), Math.power(1, Float.nan), Math.power(-1, Float.infinity))
print(Math.arc_tan2(0.0, -0.0), Math.arc_tan2(-0.0, -0.0), Math.arc_tan2(Float.infinity, -Float.infinity), Math.natural_log(-0.0), Math.sin(Float.infinity), Math.sin(-0.0))
